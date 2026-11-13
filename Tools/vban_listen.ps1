<#
Listens for VBAN on Windows and reports what arrives — the quickest check that a Network Audio
Sender on a Mac is reaching this PC, with nothing to install. It does not play the audio; for
that, use Voicemeeter's incoming VBAN streams once this shows packets arriving.

    powershell -ExecutionPolicy Bypass -File vban_listen.ps1

Once a second, one line per stream heard:

    Mac Audio  from 192.0.2.20   16-bit 2 ch 48 kHz   188 pkt/s   lost 0   peak -18.2 dBFS

(192.0.2.20 stands in for whatever the sending Mac's address is.) In the Sender, add this PC's
IPv4 address — `ipconfig` shows it — as a target, port 6980, and start it.

Only one program can listen on a port: close Voicemeeter, or switch off its VBAN, while this
runs. The first run may ask Windows Firewall to allow PowerShell on private networks — allow it,
or nothing will arrive. Ctrl+C stops it.
#>
param(
    [int]$Port = 6980,
    [int]$Seconds = 0          # 0 = until Ctrl+C
)

$rates = @(6000, 12000, 24000, 48000, 96000, 192000, 384000, 8000, 16000, 32000, 64000,
           128000, 256000, 512000, 11025, 22050, 44100, 88200, 176400, 352800, 705600)
$bytesPer = @{ 1 = 2; 2 = 3; 3 = 4; 4 = 4; 5 = 8 }
$typeName = @{ 1 = '16-bit'; 2 = '24-bit'; 3 = '32-bit'; 4 = 'float32'; 5 = 'float64' }

try {
    $udp = New-Object System.Net.Sockets.UdpClient($Port)
} catch {
    Write-Host "Could not listen on UDP $Port — another program has it (Voicemeeter's VBAN?)."
    exit 1
}
$udp.Client.ReceiveTimeout = 250
Write-Host "Listening for VBAN on UDP $Port. Ctrl+C to stop."

$streams = @{}
$clock = [Diagnostics.Stopwatch]::StartNew()
$nextReport = 1.0
$any = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)

try {
    while ($Seconds -eq 0 -or $clock.Elapsed.TotalSeconds -lt $Seconds) {
        try { $data = $udp.Receive([ref]$any) } catch { $data = $null }

        if ($data -and $data.Length -gt 28 -and $data[0] -eq 0x56 -and $data[1] -eq 0x42 `
                -and $data[2] -eq 0x41 -and $data[3] -eq 0x4E -and ($data[4] -band 0xE0) -eq 0 `
                -and ($data[7] -band 0xF0) -eq 0) {
            $type = $data[7] -band 0x07
            $rateIndex = $data[4] -band 0x1F
            if ($bytesPer.ContainsKey([int]$type) -and $rateIndex -lt $rates.Count) {
                $frames = $data[5] + 1
                $channels = $data[6] + 1
                $payload = $frames * $channels * $bytesPer[[int]$type]
                if ($data.Length -eq 28 + $payload) {
                    $name = ([Text.Encoding]::ASCII.GetString($data, 8, 16)).Split([char]0)[0]
                    $key = "$($any.Address)/$name"
                    $counter = [BitConverter]::ToUInt32($data, 24)
                    if (-not $streams.ContainsKey($key)) {
                        $streams[$key] = @{ Name = $name; From = "$($any.Address)"; Packets = 0; Window = 0
                                            Lost = 0; Next = $counter; Peak = 0.0
                                            Format = "$($typeName[[int]$type]) $channels ch $($rates[$rateIndex] / 1000) kHz" }
                        Write-Host "Found '$name' from $($any.Address) — $($streams[$key].Format)"
                    }
                    $s = $streams[$key]
                    $gap = [int64]$counter - [int64]$s.Next
                    if ($gap -gt 0 -and $gap -lt 64) { $s.Lost += $gap }
                    $s.Next = [uint32](([int64]$counter + 1) % 4294967296)
                    $s.Packets++; $s.Window++
                    # A level from the first samples of each packet: enough to see signal, cheap
                    # enough for PowerShell to keep up.
                    if ($type -eq 1) {
                        for ($i = 0; $i -lt [Math]::Min(64, $frames * $channels); $i++) {
                            $v = [Math]::Abs([BitConverter]::ToInt16($data, 28 + $i * 2)) / 32768.0
                            if ($v -gt $s.Peak) { $s.Peak = $v }
                        }
                    } elseif ($type -eq 2) {
                        for ($i = 0; $i -lt [Math]::Min(64, $frames * $channels); $i++) {
                            $o = 28 + $i * 3
                            $v = [int]$data[$o] -bor ([int]$data[$o + 1] -shl 8) -bor ([int]$data[$o + 2] -shl 16)
                            if ($v -band 0x800000) { $v -= 0x1000000 }
                            $v = [Math]::Abs($v) / 8388608.0
                            if ($v -gt $s.Peak) { $s.Peak = $v }
                        }
                    }
                }
            }
        }

        if ($clock.Elapsed.TotalSeconds -ge $nextReport) {
            $nextReport += 1.0
            foreach ($s in $streams.Values) {
                $db = if ($s.Peak -gt 0.00001) { '{0:N1} dBFS' -f (20 * [Math]::Log10($s.Peak)) } else { 'silent' }
                Write-Host ('{0}  from {1}   {2}   {3} pkt/s   lost {4}   peak {5}' -f `
                    $s.Name, $s.From, $s.Format, $s.Window, $s.Lost, $db)
                $s.Window = 0; $s.Peak = 0.0
            }
        }
    }
}
finally {
    $udp.Close()
    Write-Host "Stopped."
}
