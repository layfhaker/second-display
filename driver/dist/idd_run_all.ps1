$log = 'C:\idd-dist\install_log.txt'
"=== START $(Get-Date -Format o) ===" | Out-File $log -Encoding utf8
function L($m){ $m | Out-File $log -Append -Encoding utf8 }

# testsigning state
L "--- bcdedit testsigning ---"
(bcdedit /enum '{current}' | Select-String 'testsigning') 2>&1 | ForEach-Object { L $_.ToString() }

# trust the test cert (in case update reset trust)
L "--- import cert ---"
try {
  Import-Certificate -FilePath 'C:\idd-dist\SecondDisplayTest.cer' -CertStoreLocation 'Cert:\LocalMachine\Root' -EA Stop | Out-Null
  Import-Certificate -FilePath 'C:\idd-dist\SecondDisplayTest.cer' -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' -EA Stop | Out-Null
  L "cert imported to Root + TrustedPublisher"
} catch { L ("cert import: " + $_.Exception.Message) }

# run the clean install, capture everything
L "--- clean install ---"
try {
  & 'C:\idd-dist\idd_clean_install.ps1' *>&1 | ForEach-Object { L ($_ | Out-String).TrimEnd() }
} catch { L ("clean_install ERROR: " + $_.Exception.Message) }

"=== DONE $(Get-Date -Format o) ===" | Out-File $log -Append -Encoding utf8
