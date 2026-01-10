# meta-data.ps1
Param(
    [Parameter(Mandatory=$true)] [String]$VMName
)

$Content = @"
instance-id: $VMName
local-hostname: $VMName
"@

return $Content