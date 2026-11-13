<#
Sends a VBAN test tone from Windows to Network Audio Grabber. Nothing to install: this runs
in the PowerShell that ships with Windows.

    powershell -ExecutionPolicy Bypass -File vban_tone.ps1 -Dest 192.0.2.20

192.0.2.20 stands in for the Mac's own address: use the one shown under Settings -> Discovery.
A broadcast address from the same list (192.0.2.255 here) works too, and reaches every
receiver on that network at once — and every other device on it, so keep such a test short.

Stereo, 16-bit, 48 kHz, 256 samples a packet: what Voicemeeter sends by default. Ctrl+C stops it.
The Mac side: Settings -> Discovery -> VBAN on. The stream appears as "PC Tone".
#>
param(
    [Parameter(Mandatory = $true)][string]$Dest,   # the Mac's address, from the VBAN footer in Settings
    [int]$Port = 6980,
    [string]$Name = "PC Tone",
    [int]$Freq = 440,                             # whole hertz, so the loop below is seamless
    [double]$Level = 0.25,
    [int]$Seconds = 0                             # 0 = until Ctrl+C
)

$rate = 48000; $channels = 2; $frames = 256
$payloadBytes = $frames * $channels * 2

# Two seconds of tone: 96000 frames is exactly 375 packets of 256, so it loops without a click.
Write-Host "Preparing tone..."
$loopFrames = 2 * $rate
$pcm = New-Object byte[] ($loopFrames * $channels * 2)
$amp = $Level * 32767
$step = 2 * [Math]::PI * $Freq / $rate
for ($n = 0; $n -lt $loopFrames; $n++) {
    $v = [int16][Math]::Round($amp * [Math]::Sin($step * $n))
    $lo = [byte]($v -band 0xFF); $hi = [byte](($v -shr 8) -band 0xFF)
    $i = $n * $channels * 2
    $pcm[$i] = $lo; $pcm[$i + 1] = $hi          # left
    $pcm[$i + 2] = $lo; $pcm[$i + 3] = $hi      # right
}

# Header: "VBAN", rate index 3 (48 kHz) with sub-protocol audio, frames - 1, channels - 1,
# data type 1 (16-bit PCM), 16-byte name, then a 32-bit frame counter filled in per packet.
$packet = New-Object byte[] (28 + $payloadBytes)
[byte[]](0x56, 0x42, 0x41, 0x4E, 3, ($frames - 1), ($channels - 1), 1) | ForEach-Object -Begin { $k = 0 } -Process { $packet[$k++] = $_ }
$nameBytes = [Text.Encoding]::ASCII.GetBytes($Name)
[Array]::Copy($nameBytes, 0, $packet, 8, [Math]::Min(16, $nameBytes.Length))

$udp = New-Object System.Net.Sockets.UdpClient
# Windows refuses to send to a broadcast address unless the socket asks for it. Harmless for a
# unicast destination.
$udp.EnableBroadcast = $true
$udp.Connect($Dest, $Port)
Write-Host "Sending '$Name' to ${Dest}:$Port (16-bit, 2 ch, 48 kHz). Ctrl+C to stop."

$periodMs = 1000.0 * $frames / $rate            # 5.33 ms
$packetsInLoop = $loopFrames / $frames          # 375
[uint32]$counter = 0
$clock = [Diagnostics.Stopwatch]::StartNew()
$next = 0.0
try {
    while ($Seconds -eq 0 -or $clock.Elapsed.TotalSeconds -lt $Seconds) {
        $now = $clock.Elapsed.TotalMilliseconds
        while ($next -le $now) {
            $c = [BitConverter]::GetBytes($counter)
            $packet[24] = $c[0]; $packet[25] = $c[1]; $packet[26] = $c[2]; $packet[27] = $c[3]
            [Array]::Copy($pcm, [int]($counter % $packetsInLoop) * $payloadBytes, $packet, 28, $payloadBytes)
            [void]$udp.Send($packet, $packet.Length)
            $counter++
            $next += $periodMs
            if ($next -lt $now - 100) { $next = $now }   # fell badly behind; catch up
        }
        [Threading.Thread]::Sleep(1)
    }
}
finally {
    $udp.Close()
    Write-Host "Stopped after $counter packets."
}
