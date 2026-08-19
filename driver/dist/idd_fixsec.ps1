# Runs ELEVATED. Restores the known-good test config the OS update reset.
$mark = 'C:\idd-dist\fixsec_done.txt'
"START $(Get-Date -Format o)" | Out-File $mark -Encoding utf8
"elevated=" + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) | Out-File $mark -Append -Encoding utf8

# 1) disable UAC filtering so guestcontrol gets full admin token
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -Value 0 -Type DWord
"EnableLUA set to 0" | Out-File $mark -Append -Encoding utf8

# 2) test signing on (for our test-signed driver)
(bcdedit /set testsigning on) 2>&1 | Out-File $mark -Append -Encoding utf8

# 3) trust the test cert
try {
  Import-Certificate -FilePath 'C:\idd-dist\SecondDisplayTest.cer' -CertStoreLocation 'Cert:\LocalMachine\Root' -EA Stop | Out-Null
  Import-Certificate -FilePath 'C:\idd-dist\SecondDisplayTest.cer' -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' -EA Stop | Out-Null
  "cert trusted" | Out-File $mark -Append -Encoding utf8
} catch { "cert err: $($_.Exception.Message)" | Out-File $mark -Append -Encoding utf8 }

"REBOOTING $(Get-Date -Format o)" | Out-File $mark -Append -Encoding utf8
shutdown /r /t 4 /c "SecondDisplay test config restore"
