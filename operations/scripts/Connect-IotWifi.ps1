$ssid = "IOT-WIFI"
$securePassword = Read-Host "Enter password for $ssid" -AsSecureString
$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($securePassword)
)
$profileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$ssid</name>
    <SSIDConfig>
        <SSID>
            <name>$ssid</name>
        </SSID>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>auto</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>WPA2PSK</authentication>
                <encryption>AES</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
            <sharedKey>
                <keyType>passPhrase</keyType>
                <protected>false</protected>
                <keyMaterial>$plainPassword</keyMaterial>
            </sharedKey>
        </security>
    </MSM>
</WLANProfile>
"@
$path = "$env:TEMP\$($ssid -replace ' ','_').xml"
$profileXml | Out-File -Encoding UTF8 $path
netsh wlan add profile filename="$path"
Remove-Item $path -Force   # the XML holds the passphrase in plain text
netsh wlan connect name="$ssid"
