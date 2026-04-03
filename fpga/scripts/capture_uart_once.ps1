param(
  [string]$Port,
  [string]$OutFile,
  [int]$Seconds = 15,
  [string]$SendText = "",
  [string]$SendHex = "",
  [int]$OpenDelayMs = 200,
  [int]$SendDelayMs = 0
)

$sp = $null
$chunks = New-Object System.Collections.Generic.List[string]

try {
  $sp = New-Object System.IO.Ports.SerialPort
  $sp.PortName = $Port
  $sp.BaudRate = 115200
  $sp.Parity = [System.IO.Ports.Parity]::None
  $sp.DataBits = 8
  $sp.StopBits = [System.IO.Ports.StopBits]::One
  $sp.Handshake = [System.IO.Ports.Handshake]::None
  $sp.ReadTimeout = 200
  $sp.WriteTimeout = 200
  $sp.DtrEnable = $false
  $sp.RtsEnable = $false
  $sp.Encoding = [System.Text.Encoding]::ASCII
  $sp.Open()

  Start-Sleep -Milliseconds $OpenDelayMs

  if ($SendText) {
    if ($SendDelayMs -gt 0) { Start-Sleep -Milliseconds $SendDelayMs }
    $sp.Write($SendText)
  }
  elseif ($SendHex) {
    if ($SendDelayMs -gt 0) { Start-Sleep -Milliseconds $SendDelayMs }
    $hexClean = ($SendHex -replace '[^0-9A-Fa-f]', '')
    if (($hexClean.Length % 2) -ne 0) {
      throw "SendHex must contain an even number of hex digits"
    }
    $byteCount = $hexClean.Length / 2
    $bytes = New-Object byte[] $byteCount
    for ($i = 0; $i -lt $byteCount; $i++) {
      $bytes[$i] = [Convert]::ToByte($hexClean.Substring($i * 2, 2), 16)
    }
    $sp.Write($bytes, 0, $bytes.Length)
  }

  $end = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $end) {
    $data = $sp.ReadExisting()
    if ($data) { [void]$chunks.Add($data) }
    Start-Sleep -Milliseconds 50
  }
}
catch {
  [void]$chunks.Add("[OPEN_ERROR] $($_.Exception.Message)`r`n")
}
finally {
  if ($sp -and $sp.IsOpen) { $sp.Close() }
}

[System.IO.File]::WriteAllText($OutFile, ($chunks -join ''))
