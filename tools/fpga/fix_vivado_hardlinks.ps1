# Replace hardlinks under Vivado scripts/rt/data with independent copies.
# Vivado 2021.1 shares files with Vitis via NTFS hardlinks; the MIG debug-core
# synthesis subprocess fails to read some of them ("no such file or directory").
# Converting them to real copies removes the dependency on the hardlink target.
$ErrorActionPreference = "Stop"
$root = "D:\Xilinx\Vivado\2021.1\scripts\rt\data"
$log = "D:\workspace\.lr_scratch4\hardlink_fix.log"
$fixed = 0
$failed = 0

Get-ChildItem $root -Recurse -File -Force | ForEach-Object {
    $f = $_
    if ($f.LinkType -eq "HardLink") {
        $tmp = $f.FullName + ".tmp_copy"
        try {
            # copy the file content to a temp file in the same dir (same volume)
            Copy-Item -LiteralPath $f.FullName -Destination $tmp -Force
            # remove the hardlink, then move the copy into place
            Remove-Item -LiteralPath $f.FullName -Force
            Move-Item -LiteralPath $tmp -Destination $f.FullName -Force
            # ensure it is no longer a hardlink
            $new = Get-Item -LiteralPath $f.FullName -Force
            if ($new.LinkType -eq $null -or $new.LinkType -eq "None") {
                $fixed++
                Add-Content -Path $log -Value ("FIXED: " + $f.FullName)
            } else {
                $failed++
                Add-Content -Path $log -Value ("STILL LINK: " + $f.FullName + " type=" + $new.LinkType)
            }
        } catch {
            $failed++
            Add-Content -Path $log -Value ("FAILED: " + $f.FullName + " : " + $_.Exception.Message)
        }
    }
}

Write-Output ("Fixed: $fixed, Failed: $failed")
Write-Output ("Log: $log")
