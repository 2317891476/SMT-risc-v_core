[CmdletBinding()]
param(
    [string[]]$Tests,
    [switch]$NoGtkWave,
    [switch]$StopOnError,
    [switch]$DryRun,
    [string]$DryRunReportPath = ".sisyphus/evidence/task-2-sim-entrypoint.md"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CompDir = (Resolve-Path $PSScriptRoot).Path
$RepoRoot = (Resolve-Path (Join-Path $CompDir "..")).Path
$RomDir = Join-Path $RepoRoot "rom"

$OutRoot = Join-Path $CompDir "out_iverilog"
$BinDir = Join-Path $OutRoot "bin"
$LogDir = Join-Path $OutRoot "logs"
$WaveDir = Join-Path $OutRoot "waves"

if ($null -ne $Tests) {
    $normalizedTests = New-Object System.Collections.Generic.List[string]
    foreach ($testArg in $Tests) {
        foreach ($candidate in ($testArg -split ",")) {
            $trimmed = $candidate.Trim()
            if ($trimmed) {
                $normalizedTests.Add($trimmed)
            }
        }
    }
    $Tests = @($normalizedTests)
}

if (-not $PSBoundParameters.ContainsKey("Tests") -or $null -eq $Tests -or $Tests.Count -eq 0) {
    $Tests = @("test1.s", "test2.S")
}

function Assert-CommandExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool not found in PATH: $Name"
    }
}

function Assert-PathExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Description not found: $Path"
    }
}

function Resolve-FromCompDir {
    param([Parameter(Mandatory = $true)][string]$PathText)

    if ([System.IO.Path]::IsPathRooted($PathText)) {
        return [System.IO.Path]::GetFullPath($PathText)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $CompDir $PathText))
}

function Resolve-FromRepoRoot {
    param([Parameter(Mandatory = $true)][string]$PathText)

    if ([System.IO.Path]::IsPathRooted($PathText)) {
        return [System.IO.Path]::GetFullPath($PathText)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $PathText))
}

function Add-UniquePath {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$List,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not $List.Contains($Path)) {
        $List.Add($Path)
    }
}

function Merge-PathLists {
    param(
        [Parameter(Mandatory = $true)][string[]]$Primary,
        [Parameter(Mandatory = $true)][string[]]$Secondary
    )

    $merged = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Primary) {
        Add-UniquePath -List $merged -Path $item
    }
    foreach ($item in $Secondary) {
        Add-UniquePath -List $merged -Path $item
    }
    return @($merged)
}

function Quote-Arg {
    param([Parameter(Mandatory = $true)][string]$Text)

    if ($Text -match '[\s"]') {
        return '"{0}"' -f $Text.Replace('"', '\"')
    }
    return $Text
}

function Format-CommandLine {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][string[]]$Args
    )

    return ((@($Tool) + $Args) | ForEach-Object { Quote-Arg -Text $_ }) -join ' '
}

function Get-FlowConfig {
    return [PSCustomObject]@{
        Name           = "Standard"
        TestbenchPath  = Resolve-FromCompDir -PathText "tb.sv"
        ModuleListPath = Resolve-FromCompDir -PathText "module_list"
        TopModule      = "tb"
        TmpVcdPath     = Join-Path $CompDir "tb.vcd"
        DefaultIncDirs = @(
            (Resolve-FromCompDir -PathText "."),
            (Resolve-FromCompDir -PathText "../rtl/")
        )
    }
}

function Get-IverilogSources {
    param([Parameter(Mandatory = $true)][string]$ListPath)

    $srcList = New-Object System.Collections.Generic.List[string]
    $incList = New-Object System.Collections.Generic.List[string]

    foreach ($line in Get-Content -Path $ListPath) {
        $trim = $line.Trim()
        if (-not $trim) { continue }
        if ($trim.StartsWith("//") -or $trim.StartsWith("#")) { continue }

        if ($trim.StartsWith("+incdir+")) {
            $incPath = $trim.Substring(8).Trim()
            if ($incPath) {
                $resolvedInc = Resolve-FromCompDir -PathText $incPath
                Assert-PathExists -Path $resolvedInc -Description "Include directory"
                Add-UniquePath -List $incList -Path $resolvedInc
            }
            continue
        }

        $tokens = $trim -split "\s+"
        foreach ($token in $tokens) {
            if ($token -match "\.(v|sv)$") {
                $resolvedSrc = Resolve-FromCompDir -PathText $token
                Assert-PathExists -Path $resolvedSrc -Description "RTL source"
                Add-UniquePath -List $srcList -Path $resolvedSrc
            }
        }
    }

    if ($srcList.Count -eq 0) {
        throw "No Verilog sources found in $ListPath"
    }

    return [PSCustomObject]@{
        Sources = @($srcList)
        IncDirs = @($incList)
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][string[]]$Args
    )

    & $Tool @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $Tool $($Args -join ' ')"
    }
}

function Get-RomBuildPlan {
    param([Parameter(Mandatory = $true)][string]$AsmName)

    $asmPath = Join-Path $RomDir $AsmName
    Assert-PathExists -Path $asmPath -Description "ASM file"

    $linkerPath = Join-Path $RomDir "harvard_link.ld"
    Assert-PathExists -Path $linkerPath -Description "Linker script"

    $elfPath = Join-Path $RomDir "main_s.elf"
    $objPath = Join-Path $RomDir "main_s.o"
    $mapPath = Join-Path $RomDir "main_s.map"
    $dumpPath = Join-Path $RomDir "main_s.dump"
    $instHexPath = Join-Path $RomDir "inst.hex"
    $dataHexPath = Join-Path $RomDir "data.hex"

    return [PSCustomObject]@{
        AsmName         = $AsmName
        AsmPath         = $asmPath
        LinkerPath      = $linkerPath
        ElfPath         = $elfPath
        ObjPath         = $objPath
        MapPath         = $mapPath
        DumpPath        = $dumpPath
        InstHexPath     = $instHexPath
        DataHexPath     = $dataHexPath
        GccArgs         = @(
            "-nostdlib", "-nostartfiles", "-Wl,--build-id=none",
            "-Wl,-T,$linkerPath",
            "-Wl,-Map,$mapPath",
            "-march=rv32i", "-mabi=ilp32",
            $asmPath,
            "-o", $elfPath
        )
        ObjcopyObjArgs  = @(
            $elfPath, "-O", "elf32-littleriscv", $objPath
        )
        ObjdumpArgs     = @(
            "-S", "-l",
            $elfPath,
            "-M", "no-aliases,numeric"
        )
        InstHexArgs     = @(
            "-j", ".text", "-O", "verilog", $elfPath, $instHexPath
        )
        DataHexArgs     = @(
            "-j", ".data", "-j", ".sdata", "-O", "verilog", $elfPath, $dataHexPath
        )
    }
}

function Build-RomImage {
    param([Parameter(Mandatory = $true)][psobject]$Plan)

    Invoke-Checked -Tool "riscv-none-elf-gcc" -Args $Plan.GccArgs
    Invoke-Checked -Tool "riscv-none-elf-objcopy" -Args $Plan.ObjcopyObjArgs
    Invoke-Checked -Tool "riscv-none-elf-objdump" -Args $Plan.ObjdumpArgs | Set-Content -Path $Plan.DumpPath -Encoding utf8
    Invoke-Checked -Tool "riscv-none-elf-objcopy" -Args $Plan.InstHexArgs
    Invoke-Checked -Tool "riscv-none-elf-objcopy" -Args $Plan.DataHexArgs
}

function Get-TestPlan {
    param(
        [Parameter(Mandatory = $true)][string]$AsmName,
        [Parameter(Mandatory = $true)][psobject]$FlowConfig,
        [Parameter(Mandatory = $true)][string[]]$Sources,
        [Parameter(Mandatory = $true)][string[]]$IncDirs
    )

    $base = [System.IO.Path]::GetFileNameWithoutExtension($AsmName)
    $simvPath = Join-Path $BinDir ("tb_{0}.out" -f $base)
    $logPath = Join-Path $LogDir ("{0}.log" -f $base)
    $wavePath = Join-Path $WaveDir ("{0}.vcd" -f $base)

    $iverilogArgs = @("-g2012", "-s", $FlowConfig.TopModule, "-o", $simvPath)
    foreach ($inc in $IncDirs) {
        $iverilogArgs += @("-I", $inc)
    }
    $iverilogArgs += $Sources
    $iverilogArgs += $FlowConfig.TestbenchPath

    return [PSCustomObject]@{
        Test         = $AsmName
        Base         = $base
        RomPlan      = Get-RomBuildPlan -AsmName $AsmName
        SimvPath     = $simvPath
        LogPath      = $logPath
        WavePath     = $wavePath
        IverilogArgs = $iverilogArgs
        VvpArgs      = @($simvPath)
    }
}

function Get-SimulationStatus {
    param([Parameter(Mandatory = $true)][string]$LogPath)

    $simText = Get-Content -Path $LogPath -Raw
    if ($simText -match "Test PASS" -or $simText -match "This case is pass") {
        return "PASS"
    }
    if ($simText -match "Test FAILED" -or $simText -match "This case is failed" -or $simText -match "Timeout Error") {
        return "FAIL"
    }
    return "DONE"
}

function Write-FlowSummary {
    param(
        [Parameter(Mandatory = $true)][psobject]$FlowConfig,
        [Parameter(Mandatory = $true)][string[]]$IncDirs,
        [Parameter(Mandatory = $true)][string[]]$Sources
    )

    Write-Host ("[INFO] Selected flow : {0}" -f $FlowConfig.Name)
    Write-Host ("[INFO] Module list   : {0}" -f $FlowConfig.ModuleListPath)
    Write-Host ("[INFO] Testbench     : {0}" -f $FlowConfig.TestbenchPath)
    Write-Host ("[INFO] Top module    : {0}" -f $FlowConfig.TopModule)
    Write-Host "[INFO] Include dirs  :"
    foreach ($inc in $IncDirs) {
        Write-Host ("  - {0}" -f $inc)
    }
    Write-Host ("[INFO] Source count  : {0}" -f $Sources.Count)
}

function Write-DryRunReport {
    param(
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][psobject]$FlowConfig,
        [Parameter(Mandatory = $true)][string[]]$IncDirs,
        [Parameter(Mandatory = $true)][string[]]$Sources,
        [Parameter(Mandatory = $true)][psobject[]]$Plans
    )

    $reportDir = Split-Path -Parent $ReportPath
    if ($reportDir) {
        New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Task 2 V2 simulation entrypoint dry-run")
    $lines.Add("")
    $lines.Add(("- Generated: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss K")))
    $lines.Add(("- Flow: {0}" -f $FlowConfig.Name))
    $lines.Add(("- Module list: {0}" -f $FlowConfig.ModuleListPath))
    $lines.Add(("- Testbench: {0}" -f $FlowConfig.TestbenchPath))
    $lines.Add(("- Top module: {0}" -f $FlowConfig.TopModule))
    $lines.Add(("- Dry-run only: {0}" -f $DryRun.IsPresent))
    $lines.Add(("- NoGtkWave requested: {0}" -f $NoGtkWave.IsPresent))
    $lines.Add(("- Tests: {0}" -f ($Plans.Test -join ", ")))
    $lines.Add("")
    $lines.Add("## Include directories")
    foreach ($inc in $IncDirs) {
        $lines.Add(("- {0}" -f $inc))
    }
    $lines.Add("")
    $lines.Add("## Resolved source manifest")
    $index = 1
    foreach ($src in $Sources) {
        $lines.Add(("{0}. {1}" -f $index, $src))
        $index += 1
    }

    foreach ($plan in $Plans) {
        $lines.Add("")
        $lines.Add(("## {0}" -f $plan.Test))
        $lines.Add(("- ROM source: {0}" -f $plan.RomPlan.AsmPath))
        $lines.Add(("- Simulation binary: {0}" -f $plan.SimvPath))
        $lines.Add(("- Log path: {0}" -f $plan.LogPath))
        $lines.Add(("- Wave path: {0}" -f $plan.WavePath))
        $lines.Add(("- GCC: {0}" -f (Format-CommandLine -Tool "riscv-none-elf-gcc" -Args $plan.RomPlan.GccArgs)))
        $lines.Add(("- Objcopy (ELF): {0}" -f (Format-CommandLine -Tool "riscv-none-elf-objcopy" -Args $plan.RomPlan.ObjcopyObjArgs)))
        $lines.Add(("- Objdump: {0}" -f (Format-CommandLine -Tool "riscv-none-elf-objdump" -Args $plan.RomPlan.ObjdumpArgs)))
        $lines.Add(("- Objcopy (inst.hex): {0}" -f (Format-CommandLine -Tool "riscv-none-elf-objcopy" -Args $plan.RomPlan.InstHexArgs)))
        $lines.Add(("- Objcopy (data.hex): {0}" -f (Format-CommandLine -Tool "riscv-none-elf-objcopy" -Args $plan.RomPlan.DataHexArgs)))
        $lines.Add(("- Iverilog: {0}" -f (Format-CommandLine -Tool "iverilog" -Args $plan.IverilogArgs)))
        $lines.Add(("- VVP: {0}" -f (Format-CommandLine -Tool "vvp" -Args $plan.VvpArgs)))
    }

    Set-Content -Path $ReportPath -Value $lines -Encoding utf8
}

$flowConfig = Get-FlowConfig
Assert-PathExists -Path $flowConfig.TestbenchPath -Description "Testbench"
Assert-PathExists -Path $flowConfig.ModuleListPath -Description "Module list"

New-Item -ItemType Directory -Force -Path $OutRoot, $BinDir, $LogDir, $WaveDir | Out-Null

$parsed = Get-IverilogSources -ListPath $flowConfig.ModuleListPath
$sources = $parsed.Sources
$incdirs = Merge-PathLists -Primary $flowConfig.DefaultIncDirs -Secondary $parsed.IncDirs

foreach ($incDir in $incdirs) {
    Assert-PathExists -Path $incDir -Description "Include directory"
}

$testPlans = New-Object System.Collections.Generic.List[psobject]
foreach ($test in $Tests) {
    $testPlans.Add((Get-TestPlan -AsmName $test -FlowConfig $flowConfig -Sources $sources -IncDirs $incdirs))
}

Write-FlowSummary -FlowConfig $flowConfig -IncDirs $incdirs -Sources $sources

if ($DryRun) {
    $reportPath = Resolve-FromRepoRoot -PathText $DryRunReportPath
    Write-DryRunReport -ReportPath $reportPath -FlowConfig $flowConfig -IncDirs $incdirs -Sources $sources -Plans @($testPlans)
    Write-Host ""
    Write-Host "[INFO] Dry-run only; no compile or simulation commands were executed."
    Write-Host ("[INFO] Dry-run report: {0}" -f $reportPath)
    return
}

Assert-CommandExists -Name "riscv-none-elf-gcc"
Assert-CommandExists -Name "riscv-none-elf-objdump"
Assert-CommandExists -Name "riscv-none-elf-objcopy"
Assert-CommandExists -Name "iverilog"
Assert-CommandExists -Name "vvp"

$results = New-Object System.Collections.Generic.List[psobject]

foreach ($plan in $testPlans) {
    Write-Host ""
    Write-Host ("========== Running {0} ({1}) ==========" -f $plan.Test, $flowConfig.Name)

    try {
        Build-RomImage -Plan $plan.RomPlan
        Invoke-Checked -Tool "iverilog" -Args $plan.IverilogArgs

        if (Test-Path $flowConfig.TmpVcdPath) {
            Remove-Item -Path $flowConfig.TmpVcdPath -Force
        }

        $vvpOut = & vvp @($plan.VvpArgs) 2>&1
        $vvpOut | Set-Content -Path $plan.LogPath -Encoding utf8
        if ($LASTEXITCODE -ne 0) {
            throw "vvp failed for $($plan.Test)"
        }

        $resolvedWavePath = ""
        if (Test-Path $flowConfig.TmpVcdPath) {
            Move-Item -Path $flowConfig.TmpVcdPath -Destination $plan.WavePath -Force
            $resolvedWavePath = $plan.WavePath
        }

        $results.Add([PSCustomObject]@{
            Test   = $plan.Test
            Status = Get-SimulationStatus -LogPath $plan.LogPath
            Log    = $plan.LogPath
            Wave   = $resolvedWavePath
        })
    } catch {
        Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
        $results.Add([PSCustomObject]@{
            Test   = $plan.Test
            Status = "ERROR"
            Log    = $plan.LogPath
            Wave   = ""
        })
        if ($StopOnError) {
            throw
        }
    }
}

Write-Host ""
Write-Host "========== Summary =========="
$results | Format-Table -AutoSize

if (-not $NoGtkWave) {
    $lastWave = $results | Where-Object { $_.Wave -and (Test-Path $_.Wave) } | Select-Object -Last 1
    if ($lastWave) {
        if (Get-Command "gtkwave" -ErrorAction SilentlyContinue) {
            Start-Process -FilePath "gtkwave" -ArgumentList "`"$($lastWave.Wave)`"" | Out-Null
            Write-Host ("[INFO] gtkwave opened: {0}" -f $lastWave.Wave)
        } else {
            Write-Host "[WARN] gtkwave not found in PATH."
        }
    } else {
        Write-Host "[WARN] no VCD found, gtkwave not opened."
    }
}
