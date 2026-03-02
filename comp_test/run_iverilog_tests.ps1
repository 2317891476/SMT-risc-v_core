[CmdletBinding()]
param(
    [string[]]$Tests = @("test1.s", "test2.S"),
    [switch]$NoGtkWave,
    [switch]$StopOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CompDir = (Resolve-Path $PSScriptRoot).Path
$RepoRoot = (Resolve-Path (Join-Path $CompDir "..")).Path
$RomDir = Join-Path $RepoRoot "rom"
$TbPath = Join-Path $CompDir "tb.sv"
$ModuleListPath = Join-Path $CompDir "module_list"

$OutRoot = Join-Path $CompDir "out_iverilog"
$BinDir = Join-Path $OutRoot "bin"
$LogDir = Join-Path $OutRoot "logs"
$WaveDir = Join-Path $OutRoot "waves"
$TmpVcd = Join-Path $CompDir "tb.vcd"

New-Item -ItemType Directory -Force -Path $OutRoot, $BinDir, $LogDir, $WaveDir | Out-Null

function Assert-CommandExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool not found in PATH: $Name"
    }
}

function Resolve-FromCompDir {
    param([Parameter(Mandatory = $true)][string]$PathText)

    if ([System.IO.Path]::IsPathRooted($PathText)) {
        return [System.IO.Path]::GetFullPath($PathText)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $CompDir $PathText))
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
                $incList.Add((Resolve-FromCompDir -PathText $incPath))
            }
            continue
        }

        $tokens = $trim -split "\s+"
        foreach ($token in $tokens) {
            if ($token -match "\.(v|sv)$") {
                $srcList.Add((Resolve-FromCompDir -PathText $token))
            }
        }
    }

    $sources = $srcList | Select-Object -Unique
    $incdirs = $incList | Select-Object -Unique

    if (-not $sources -or $sources.Count -eq 0) {
        throw "No Verilog sources found in $ListPath"
    }

    return [PSCustomObject]@{
        Sources = $sources
        IncDirs = $incdirs
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

Assert-CommandExists -Name "riscv-none-elf-gcc"
Assert-CommandExists -Name "riscv-none-elf-objdump"
Assert-CommandExists -Name "riscv-none-elf-objcopy"
Assert-CommandExists -Name "iverilog"
Assert-CommandExists -Name "vvp"

function Build-RomImage {
    param([Parameter(Mandatory = $true)][string]$AsmName)

    $asmPath = Join-Path $RomDir $AsmName
    if (-not (Test-Path $asmPath)) {
        throw "ASM file not found: $asmPath"
    }

    $linkerPath = Join-Path $RomDir "harvard_link.ld"
    if (-not (Test-Path $linkerPath)) {
        throw "Linker script not found: $linkerPath"
    }

    $elfPath = Join-Path $RomDir "main_s.elf"
    $objPath = Join-Path $RomDir "main_s.o"
    $mapPath = Join-Path $RomDir "main_s.map"
    $dumpPath = Join-Path $RomDir "main_s.dump"
    $instHexPath = Join-Path $RomDir "inst.hex"
    $dataHexPath = Join-Path $RomDir "data.hex"

    Invoke-Checked -Tool "riscv-none-elf-gcc" -Args @(
        "-nostdlib", "-nostartfiles", "-Wl,--build-id=none",
        "-Wl,-T,$linkerPath",
        "-Wl,-Map,$mapPath",
        "-march=rv32i", "-mabi=ilp32",
        $asmPath,
        "-o", $elfPath
    )
    Invoke-Checked -Tool "riscv-none-elf-objcopy" -Args @(
        $elfPath, "-O", "elf32-littleriscv", $objPath
    )
    Invoke-Checked -Tool "riscv-none-elf-objdump" -Args @(
        "-S", "-l",
        $elfPath,
        "-M", "no-aliases,numeric"
    ) | Set-Content -Path $dumpPath -Encoding utf8
    Invoke-Checked -Tool "riscv-none-elf-objcopy" -Args @(
        "-j", ".text", "-O", "verilog", $elfPath, $instHexPath
    )
    Invoke-Checked -Tool "riscv-none-elf-objcopy" -Args @(
        "-j", ".data", "-j", ".sdata", "-O", "verilog", $elfPath, $dataHexPath
    )
}

$parsed = Get-IverilogSources -ListPath $ModuleListPath
$sources = $parsed.Sources
$incdirs = $parsed.IncDirs

$results = New-Object System.Collections.Generic.List[psobject]

foreach ($test in $Tests) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($test)
    $simvPath = Join-Path $BinDir ("tb_{0}.out" -f $base)
    $logPath = Join-Path $LogDir ("{0}.log" -f $base)
    $wavePath = Join-Path $WaveDir ("{0}.vcd" -f $base)

    Write-Host ""
    Write-Host ("========== Running {0} ==========" -f $test)

    try {
        Build-RomImage -AsmName $test

        $iverilogArgs = @("-g2012", "-s", "tb", "-o", $simvPath)
        foreach ($inc in $incdirs) {
            $iverilogArgs += @("-I", $inc)
        }
        $iverilogArgs += $sources
        $iverilogArgs += $TbPath

        Invoke-Checked -Tool "iverilog" -Args $iverilogArgs

        if (Test-Path $TmpVcd) {
            Remove-Item -Path $TmpVcd -Force
        }

        $vvpOut = & vvp $simvPath 2>&1
        $vvpOut | Set-Content -Path $logPath -Encoding utf8
        if ($LASTEXITCODE -ne 0) {
            throw "vvp failed for $test"
        }

        if (Test-Path $TmpVcd) {
            Move-Item -Path $TmpVcd -Destination $wavePath -Force
        } else {
            $wavePath = ""
        }

        $simText = Get-Content -Path $logPath -Raw
        if ($simText -match "This case is pass") {
            $status = "PASS"
        } elseif ($simText -match "This case is failed" -or $simText -match "Timeout Error") {
            $status = "FAIL"
        } else {
            $status = "DONE"
        }

        $results.Add([PSCustomObject]@{
            Test   = $test
            Status = $status
            Log    = $logPath
            Wave   = $wavePath
        })
    } catch {
        Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
        $results.Add([PSCustomObject]@{
            Test   = $test
            Status = "ERROR"
            Log    = $logPath
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
