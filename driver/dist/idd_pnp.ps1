$o = 'C:\idd-dist\pnp.txt'
"=== rm contents ===" | Out-File $o -Encoding utf8
Get-ChildItem 'C:\idd-dist\rm' | Select-Object Name,Length | Out-String | Out-File $o -Append -Encoding utf8
"=== INF first 14 lines ===" | Out-File $o -Append -Encoding utf8
(Get-Content 'C:\idd-dist\rm\MttVDD.inf' -TotalCount 14) | Out-File $o -Append -Encoding utf8
"=== signature of cat in guest ===" | Out-File $o -Append -Encoding utf8
(Get-AuthenticodeSignature 'C:\idd-dist\rm\mttvdd.cat').Status | Out-File $o -Append -Encoding utf8
"=== pnputil /add-driver /install ===" | Out-File $o -Append -Encoding utf8
(pnputil /add-driver 'C:\idd-dist\rm\MttVDD.inf' /install 2>&1) | Out-File $o -Append -Encoding utf8
"=== existing oem drivers (provider Mike/SecondDisplay) ===" | Out-File $o -Append -Encoding utf8
(pnputil /enum-drivers 2>&1 | Select-String -Context 0,3 'MttVDD|SecondDisplay|MikeTheTech') | Out-File $o -Append -Encoding utf8
