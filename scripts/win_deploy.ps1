# LLM WIN DEPLOY v15.0
# Fast re-deploy: stamps skip already-done steps. Second run < 60s.
# Services encoded as base64 -- no PS parser issues with Python syntax ever.
# Fixes: surya-ocr pinned <0.7, RobertaModel direct, pip stamps per package.
#
# Usage:
#   win_deploy.ps1                   -- chat mode
#   win_deploy.ps1 -Mode voice       -- LLM + ASR
#   win_deploy.ps1 -Mode doc         -- LLM + OCR + Embed
#   win_deploy.ps1 -Mode code        -- Kodify-Nano-2B
#   win_deploy.ps1 -Mode full        -- all services
#   win_deploy.ps1 -Gpus 2           -- use 2 GPUs
#   win_deploy.ps1 --stop
#   win_deploy.ps1 --status
#   win_deploy.ps1 --restart
param(
    [string]$Action = "--deploy",
    [string]$Gpus   = "1",
    [string]$Mode   = "chat"
)
if ($args.Count -gt 0 -and $Action -eq "--deploy") { $Action = $args[0] }

$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$W = "$env:USERPROFILE\llm_native"

$IDLE_LLM   = 600
$IDLE_ASR   = 300
$IDLE_OCR   = 300
$IDLE_EMBED = 900

# =============================================================================
# BASE64 PYTHON SERVICES
# Generated from compact Python; %%IDLE_XXX%% replaced at write time.
# OCR: surya-ocr 0.4-0.6 legacy API (pinned <0.7)
# EMBED: RobertaModel.from_pretrained direct (no AutoModel pickle issue)
# ASR: gigaam CTC
# =============================================================================
$OCR_B64   = "aW1wb3J0IHN5cyxqc29uLGJhc2U2NCBhcyBiNjQsdGVtcGZpbGUsb3MsdGltZSx0aHJlYWRpbmcsd2FybmluZ3MKZnJvbSBodHRwLnNlcnZlciBpbXBvcnQgSFRUUFNlcnZlcixCYXNlSFRUUFJlcXVlc3RIYW5kbGVyCndhcm5pbmdzLmZpbHRlcndhcm5pbmdzKCdpZ25vcmUnKQpvcy5lbnZpcm9uWydUT0tFTklaRVJTX1BBUkFMTEVMSVNNJ109J2ZhbHNlJwpvcy5lbnZpcm9uWydLTVBfRFVQTElDQVRFX0xJQl9PSyddPSdUUlVFJwpJRExFPSUlSURMRV9PQ1IlJQpsYXN0PVt0aW1lLnRpbWUoKV0KUz1bTm9uZV07b2s9W0ZhbHNlXTtlcnI9W05vbmVdCmRlZiBsb2FkKCk6CiAgICB0cnk6CiAgICAgICAgZnJvbSBzdXJ5YS5vY3IgaW1wb3J0IHJ1bl9vY3IgYXMgUgogICAgICAgIGZyb20gc3VyeWEubW9kZWwuZGV0ZWN0aW9uLm1vZGVsIGltcG9ydCBsb2FkX21vZGVsIGFzIGRtLGxvYWRfcHJvY2Vzc29yIGFzIGRwCiAgICAgICAgZnJvbSBzdXJ5YS5tb2RlbC5yZWNvZ25pdGlvbi5tb2RlbCBpbXBvcnQgbG9hZF9tb2RlbCBhcyBybQogICAgICAgIGZyb20gc3VyeWEubW9kZWwucmVjb2duaXRpb24ucHJvY2Vzc29yIGltcG9ydCBsb2FkX3Byb2Nlc3NvciBhcyBycAogICAgICAgIFNbMF09KFIsZG0oKSxkcCgpLHJtKCkscnAoKSk7IG9rWzBdPVRydWUKICAgICAgICBwcmludCgnb2NyIHJlYWR5JyxmbHVzaD1UcnVlKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIGVyclswXT1zdHIoZSk7IHByaW50KCdMT0FEX0VSUk9SOicrc3RyKGUpLGZpbGU9c3lzLnN0ZGVycixmbHVzaD1UcnVlKQpkZWYgb2NyKHApOgogICAgZnJvbSBQSUwgaW1wb3J0IEltYWdlCiAgICBpbWc9SW1hZ2Uub3BlbihwKS5jb252ZXJ0KCdSR0InKQogICAgUixkbSxkcCxybSxycD1TWzBdCiAgICByZXM9UihbaW1nXSxbWydydScsJ2VuJ11dLGRtLGRwLHJtLHJwKQogICAgcmV0dXJuIGNocigxMCkuam9pbihsLnRleHQgZm9yIHBnIGluIHJlcyBmb3IgbCBpbiBwZy50ZXh0X2xpbmVzIGlmIGwudGV4dC5zdHJpcCgpKQpjbGFzcyBIKEJhc2VIVFRQUmVxdWVzdEhhbmRsZXIpOgogICAgZGVmIGxvZ19tZXNzYWdlKHNlbGYsZiwqYSk6cGFzcwogICAgZGVmIGRvX0dFVChzZWxmKToKICAgICAgICBpZiBzZWxmLnBhdGghPScvaGVhbHRoJzpyZXR1cm4KICAgICAgICBzZWxmLnNlbmRfcmVzcG9uc2UoMjAwKTtzZWxmLnNlbmRfaGVhZGVyKCdDb250ZW50LVR5cGUnLCdhcHBsaWNhdGlvbi9qc29uJyk7c2VsZi5lbmRfaGVhZGVycygpCiAgICAgICAgc3Q9J29rJyBpZiBva1swXSBlbHNlICgnZXJyb3I6JytlcnJbMF1bOjEwMF0gaWYgZXJyWzBdIGVsc2UgJ2xvYWRpbmcnKQogICAgICAgIHNlbGYud2ZpbGUud3JpdGUoanNvbi5kdW1wcyh7J3N0YXR1cyc6c3R9KS5lbmNvZGUoKSkKICAgIGRlZiBkb19QT1NUKHNlbGYpOgogICAgICAgIGlmIG5vdCBva1swXToKICAgICAgICAgICAgc2VsZi5zZW5kX3Jlc3BvbnNlKDUwMyk7c2VsZi5zZW5kX2hlYWRlcignQ29udGVudC1UeXBlJywnYXBwbGljYXRpb24vanNvbicpO3NlbGYuZW5kX2hlYWRlcnMoKQogICAgICAgICAgICBzZWxmLndmaWxlLndyaXRlKGpzb24uZHVtcHMoeydlcnJvcic6ZXJyWzBdIG9yICdsb2FkaW5nJ30pLmVuY29kZSgpKTtyZXR1cm4KICAgICAgICBsYXN0WzBdPXRpbWUudGltZSgpCiAgICAgICAgYm9keT1qc29uLmxvYWRzKHNlbGYucmZpbGUucmVhZChpbnQoc2VsZi5oZWFkZXJzLmdldCgnQ29udGVudC1MZW5ndGgnLDApKSkpCiAgICAgICAgcmF3PWI2NC5iNjRkZWNvZGUoYm9keS5nZXQoJ2ltYWdlJywnJykpO2V4dD1ib2R5LmdldCgnZXh0JywnLnBuZycpCiAgICAgICAgd2l0aCB0ZW1wZmlsZS5OYW1lZFRlbXBvcmFyeUZpbGUoc3VmZml4PWV4dCxkZWxldGU9RmFsc2UpIGFzIGY6CiAgICAgICAgICAgIGYud3JpdGUocmF3KTt0bXA9Zi5uYW1lCiAgICAgICAgdHJ5OnRleHQ9b2NyKHRtcCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6dGV4dD0nRVJST1I6JytzdHIoZSkKICAgICAgICBmaW5hbGx5Om9zLnVubGluayh0bXApCiAgICAgICAgc2VsZi5zZW5kX3Jlc3BvbnNlKDIwMCk7c2VsZi5zZW5kX2hlYWRlcignQ29udGVudC1UeXBlJywnYXBwbGljYXRpb24vanNvbicpO3NlbGYuZW5kX2hlYWRlcnMoKQogICAgICAgIHNlbGYud2ZpbGUud3JpdGUoanNvbi5kdW1wcyh7J3RleHQnOnRleHR9KS5lbmNvZGUoKSkKZGVmIHdhdGNoKCk6CiAgICB3aGlsZSBUcnVlOgogICAgICAgIHRpbWUuc2xlZXAoMzApCiAgICAgICAgaWYgb2tbMF0gYW5kIHRpbWUudGltZSgpLWxhc3RbMF0+SURMRTpvcy5fZXhpdCgwKQp0aHJlYWRpbmcuVGhyZWFkKHRhcmdldD13YXRjaCxkYWVtb249VHJ1ZSkuc3RhcnQoKQp0aHJlYWRpbmcuVGhyZWFkKHRhcmdldD1sb2FkLGRhZW1vbj1UcnVlKS5zdGFydCgpCkhUVFBTZXJ2ZXIoKCcwLjAuMC4wJyw4MDEzKSxIKS5zZXJ2ZV9mb3JldmVyKCkK"
$EMBED_B64 = "aW1wb3J0IHN5cyxqc29uLG9zLHRpbWUsdGhyZWFkaW5nLHdhcm5pbmdzCmZyb20gaHR0cC5zZXJ2ZXIgaW1wb3J0IEhUVFBTZXJ2ZXIsQmFzZUhUVFBSZXF1ZXN0SGFuZGxlcgp3YXJuaW5ncy5maWx0ZXJ3YXJuaW5ncygnaWdub3JlJykKb3MuZW52aXJvblsnVE9LRU5JWkVSU19QQVJBTExFTElTTSddPSdmYWxzZScKSURMRT0lJUlETEVfRU1CRUQlJQpsYXN0PVt0aW1lLnRpbWUoKV0KVD1bTm9uZV07TT1bTm9uZV07b2s9W0ZhbHNlXTtlcnI9W05vbmVdCmRlZiBwb29sKGVtYixtYXNrKToKICAgIGltcG9ydCB0b3JjaAogICAgbT1tYXNrLnVuc3F1ZWV6ZSgtMSkuZXhwYW5kKGVtYi5zaXplKCkpLmZsb2F0KCkKICAgIHJldHVybiAodG9yY2guc3VtKGVtYiptLDEpL3RvcmNoLmNsYW1wKG0uc3VtKDEpLG1pbj0xZS05KSkudG9saXN0KCkKZGVmIGxvYWQoKToKICAgIHRyeToKICAgICAgICBmcm9tIHRyYW5zZm9ybWVycyBpbXBvcnQgQXV0b1Rva2VuaXplcixSb2JlcnRhTW9kZWwKICAgICAgICBtaWQ9J2FpLWZvcmV2ZXIvcnUtZW4tUm9TQkVSVGEnCiAgICAgICAgVFswXT1BdXRvVG9rZW5pemVyLmZyb21fcHJldHJhaW5lZChtaWQpCiAgICAgICAgTVswXT1Sb2JlcnRhTW9kZWwuZnJvbV9wcmV0cmFpbmVkKG1pZCxhZGRfcG9vbGluZ19sYXllcj1GYWxzZSkKICAgICAgICBNWzBdLmV2YWwoKTtva1swXT1UcnVlCiAgICAgICAgcHJpbnQoJ2VtYmVkIHJlYWR5JyxmbHVzaD1UcnVlKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIGVyclswXT1zdHIoZSk7cHJpbnQoJ0xPQURfRVJST1I6JytzdHIoZSksZmlsZT1zeXMuc3RkZXJyLGZsdXNoPVRydWUpCmRlZiBlbmModGV4dHMpOgogICAgaW1wb3J0IHRvcmNoCiAgICBlPVRbMF0odGV4dHMscGFkZGluZz1UcnVlLHRydW5jYXRpb249VHJ1ZSxtYXhfbGVuZ3RoPTUxMixyZXR1cm5fdGVuc29ycz0ncHQnKQogICAgd2l0aCB0b3JjaC5ub19ncmFkKCk6bz1NWzBdKCoqZSkKICAgIHJldHVybiBwb29sKG8ubGFzdF9oaWRkZW5fc3RhdGUsZVsnYXR0ZW50aW9uX21hc2snXSkKY2xhc3MgSChCYXNlSFRUUFJlcXVlc3RIYW5kbGVyKToKICAgIGRlZiBsb2dfbWVzc2FnZShzZWxmLGYsKmEpOnBhc3MKICAgIGRlZiBkb19HRVQoc2VsZik6CiAgICAgICAgaWYgc2VsZi5wYXRoIT0nL2hlYWx0aCc6cmV0dXJuCiAgICAgICAgc2VsZi5zZW5kX3Jlc3BvbnNlKDIwMCk7c2VsZi5zZW5kX2hlYWRlcignQ29udGVudC1UeXBlJywnYXBwbGljYXRpb24vanNvbicpO3NlbGYuZW5kX2hlYWRlcnMoKQogICAgICAgIHN0PSdvaycgaWYgb2tbMF0gZWxzZSAoJ2Vycm9yOicrZXJyWzBdWzoxMDBdIGlmIGVyclswXSBlbHNlICdsb2FkaW5nJykKICAgICAgICBzZWxmLndmaWxlLndyaXRlKGpzb24uZHVtcHMoeydzdGF0dXMnOnN0fSkuZW5jb2RlKCkpCiAgICBkZWYgZG9fUE9TVChzZWxmKToKICAgICAgICBpZiBub3Qgb2tbMF06CiAgICAgICAgICAgIHNlbGYuc2VuZF9yZXNwb25zZSg1MDMpO3NlbGYuc2VuZF9oZWFkZXIoJ0NvbnRlbnQtVHlwZScsJ2FwcGxpY2F0aW9uL2pzb24nKTtzZWxmLmVuZF9oZWFkZXJzKCkKICAgICAgICAgICAgc2VsZi53ZmlsZS53cml0ZShqc29uLmR1bXBzKHsnZXJyb3InOmVyclswXSBvciAnbG9hZGluZyd9KS5lbmNvZGUoKSk7cmV0dXJuCiAgICAgICAgbGFzdFswXT10aW1lLnRpbWUoKQogICAgICAgIGJvZHk9anNvbi5sb2FkcyhzZWxmLnJmaWxlLnJlYWQoaW50KHNlbGYuaGVhZGVycy5nZXQoJ0NvbnRlbnQtTGVuZ3RoJywwKSkpKQogICAgICAgIHRleHRzPWJvZHkuZ2V0KCdpbnB1dCcsW10pCiAgICAgICAgaWYgaXNpbnN0YW5jZSh0ZXh0cyxzdHIpOnRleHRzPVt0ZXh0c10KICAgICAgICB0cnk6CiAgICAgICAgICAgIHZlY3M9ZW5jKHRleHRzKQogICAgICAgICAgICBkYXRhPVt7J2luZGV4JzppLCdlbWJlZGRpbmcnOnZ9IGZvciBpLHYgaW4gZW51bWVyYXRlKHZlY3MpXQogICAgICAgICAgICBzZWxmLnNlbmRfcmVzcG9uc2UoMjAwKTtzZWxmLnNlbmRfaGVhZGVyKCdDb250ZW50LVR5cGUnLCdhcHBsaWNhdGlvbi9qc29uJyk7c2VsZi5lbmRfaGVhZGVycygpCiAgICAgICAgICAgIHNlbGYud2ZpbGUud3JpdGUoanNvbi5kdW1wcyh7J29iamVjdCc6J2xpc3QnLCdkYXRhJzpkYXRhfSkuZW5jb2RlKCkpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICBzZWxmLnNlbmRfcmVzcG9uc2UoNTAwKTtzZWxmLnNlbmRfaGVhZGVyKCdDb250ZW50LVR5cGUnLCdhcHBsaWNhdGlvbi9qc29uJyk7c2VsZi5lbmRfaGVhZGVycygpCiAgICAgICAgICAgIHNlbGYud2ZpbGUud3JpdGUoanNvbi5kdW1wcyh7J2Vycm9yJzpzdHIoZSl9KS5lbmNvZGUoKSkKZGVmIHdhdGNoKCk6CiAgICB3aGlsZSBUcnVlOgogICAgICAgIHRpbWUuc2xlZXAoNjApCiAgICAgICAgaWYgb2tbMF0gYW5kIHRpbWUudGltZSgpLWxhc3RbMF0+SURMRTpvcy5fZXhpdCgwKQp0aHJlYWRpbmcuVGhyZWFkKHRhcmdldD13YXRjaCxkYWVtb249VHJ1ZSkuc3RhcnQoKQp0aHJlYWRpbmcuVGhyZWFkKHRhcmdldD1sb2FkLGRhZW1vbj1UcnVlKS5zdGFydCgpCkhUVFBTZXJ2ZXIoKCcwLjAuMC4wJyw4MDE0KSxIKS5zZXJ2ZV9mb3JldmVyKCkK"
$ASR_B64   = "aW1wb3J0IHN5cyxqc29uLGJhc2U2NCBhcyBiNjQsdGVtcGZpbGUsb3MsdGltZSx0aHJlYWRpbmcKZnJvbSBodHRwLnNlcnZlciBpbXBvcnQgSFRUUFNlcnZlcixCYXNlSFRUUFJlcXVlc3RIYW5kbGVyCklETEU9JSVJRExFX0FTUiUlCmxhc3Q9W3RpbWUudGltZSgpXTttb2RlbD1bTm9uZV0KZGVmIGxvYWQoKToKICAgIGltcG9ydCBnaWdhYW0KICAgIG1vZGVsWzBdPWdpZ2FhbS5sb2FkX21vZGVsKCdjdGMnKQpjbGFzcyBIKEJhc2VIVFRQUmVxdWVzdEhhbmRsZXIpOgogICAgZGVmIGxvZ19tZXNzYWdlKHNlbGYsZiwqYSk6cGFzcwogICAgZGVmIGRvX0dFVChzZWxmKToKICAgICAgICBpZiBzZWxmLnBhdGghPScvaGVhbHRoJzpyZXR1cm4KICAgICAgICBzZWxmLnNlbmRfcmVzcG9uc2UoMjAwKTtzZWxmLnNlbmRfaGVhZGVyKCdDb250ZW50LVR5cGUnLCdhcHBsaWNhdGlvbi9qc29uJyk7c2VsZi5lbmRfaGVhZGVycygpCiAgICAgICAgc2VsZi53ZmlsZS53cml0ZShqc29uLmR1bXBzKHsnc3RhdHVzJzonb2snfSkuZW5jb2RlKCkpCiAgICBkZWYgZG9fUE9TVChzZWxmKToKICAgICAgICBsYXN0WzBdPXRpbWUudGltZSgpCiAgICAgICAgYm9keT1qc29uLmxvYWRzKHNlbGYucmZpbGUucmVhZChpbnQoc2VsZi5oZWFkZXJzLmdldCgnQ29udGVudC1MZW5ndGgnLDApKSkpCiAgICAgICAgYXVkaW89YjY0LmI2NGRlY29kZShib2R5LmdldCgnYXVkaW8nLCcnKSkKICAgICAgICB3aXRoIHRlbXBmaWxlLk5hbWVkVGVtcG9yYXJ5RmlsZShzdWZmaXg9Jy53YXYnLGRlbGV0ZT1GYWxzZSkgYXMgZjoKICAgICAgICAgICAgZi53cml0ZShhdWRpbyk7dG1wPWYubmFtZQogICAgICAgIHRyeToKICAgICAgICAgICAgdGV4dD1tb2RlbFswXS50cmFuc2NyaWJlKHRtcCkKICAgICAgICAgICAgaWYgbm90IGlzaW5zdGFuY2UodGV4dCxzdHIpOnRleHQ9c3RyKHRleHQpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOnRleHQ9J0VSUk9SOicrc3RyKGUpCiAgICAgICAgZmluYWxseTpvcy51bmxpbmsodG1wKQogICAgICAgIHNlbGYuc2VuZF9yZXNwb25zZSgyMDApO3NlbGYuc2VuZF9oZWFkZXIoJ0NvbnRlbnQtVHlwZScsJ2FwcGxpY2F0aW9uL2pzb24nKTtzZWxmLmVuZF9oZWFkZXJzKCkKICAgICAgICBzZWxmLndmaWxlLndyaXRlKGpzb24uZHVtcHMoeyd0ZXh0Jzp0ZXh0fSkuZW5jb2RlKCkpCmRlZiB3YXRjaCgpOgogICAgd2hpbGUgVHJ1ZToKICAgICAgICB0aW1lLnNsZWVwKDMwKQogICAgICAgIGlmIHRpbWUudGltZSgpLWxhc3RbMF0+SURMRTpvcy5fZXhpdCgwKQp0aHJlYWRpbmcuVGhyZWFkKHRhcmdldD13YXRjaCxkYWVtb249VHJ1ZSkuc3RhcnQoKQpsb2FkKCkKSFRUUFNlcnZlcigoJzAuMC4wLjAnLDgwMTEpLEgpLnNlcnZlX2ZvcmV2ZXIoKQo="

# Write service from base64, replacing placeholders with real timeout values
function Write-B64Service($b64, $destPath, [hashtable]$replacements) {
    $bytes   = [System.Convert]::FromBase64String($b64)
    $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    foreach ($k in $replacements.Keys) { $content = $content.Replace($k, $replacements[$k]) }
    [System.IO.File]::WriteAllText($destPath, $content, [System.Text.Encoding]::UTF8)
}

# =============================================================================
# STAMP HELPERS (idempotency)
# =============================================================================
function Get-Stamp($name) {
    $f = "$W\stamp_$name.txt"
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim() } else { return "" }
}
function Set-Stamp($name, $value) {
    [System.IO.File]::WriteAllText("$W\stamp_$name.txt", $value)
}

# pip install with stamp -- skips if already installed at expected version
function Pip-Cached($pkg, $key, $val) {
    if ((Get-Stamp $key) -eq $val) {
        Write-Host "    $pkg : cached" -ForegroundColor Green; return
    }
    Write-Host "    pip install $pkg ..." -ForegroundColor Gray
    $out  = & python -m pip install --quiet --prefer-binary $pkg 2>&1
    $fail = $out | Where-Object { $_ -match "^ERROR|Could not find|No matching" }
    if ($fail) { Write-Host "    WARN: $($fail[0])" -ForegroundColor Yellow; return }
    Set-Stamp $key $val
    Write-Host "    $pkg : done" -ForegroundColor Green
}

# =============================================================================
# DOWNLOAD MODEL (aria2c 16-conn or curl)
# =============================================================================
function Download-Model($url, $dest) {
    Remove-Item $dest -ErrorAction SilentlyContinue
    $dlUrl = if ($url -notmatch "\?") { "$url`?download=true" } else { $url }
    $fname = $url.Split('/')[-1].Split('?')[0]
    Write-Host "  Downloading $fname ..." -ForegroundColor Yellow
    if (Get-Command aria2c -ErrorAction SilentlyContinue) {
        aria2c --continue=true --max-connection-per-server=16 --split=16 --min-split-size=5M `
               --file-allocation=none --header="User-Agent: Mozilla/5.0" `
               -d (Split-Path $dest -Parent) -o (Split-Path $dest -Leaf) $dlUrl
    } else {
        curl.exe -L --retry 3 --retry-delay 3 --retry-connrefused `
            -H "User-Agent: Mozilla/5.0" --max-time 7200 $dlUrl -o $dest
    }
    if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 10MB) { return (Get-Item $dest).Length }
    Remove-Item $dest -ErrorAction SilentlyContinue
    return 0
}

# =============================================================================
# STOP / STATUS
# =============================================================================
function Invoke-Stop {
    Write-Host "Stopping all LLM services..." -ForegroundColor Yellow
    $k = 0
    Get-Process | Where-Object { $_.Name -match "llama" } | ForEach-Object {
        Stop-Process $_ -Force -ErrorAction SilentlyContinue; $k++
    }
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -eq "powershell.exe" -and $_.CommandLine -match "watchdog|asr_service|ocr_service|embed_service"
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -match "python" -and $_.CommandLine -match "asr_service|ocr_service|embed_service"
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item "$W\*.trigger" -ErrorAction SilentlyContinue
    Write-Host "Stopped $k llama + services." -ForegroundColor Green
}

function Invoke-Status {
    Write-Host "--- LLM ORCHESTRATOR STATUS ---" -ForegroundColor Cyan
    $pm = @{ 8010="LLM (llama-server)"; 8011="ASR (GigaAM)"; 8013="OCR (surya-ocr)"; 8014="Embedding (RoSBERTa)" }
    foreach ($port in 8010,8011,8013,8014) {
        try {
            $r  = Invoke-WebRequest -Uri "http://localhost:$port/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            $h  = ($r.Content | ConvertFrom-Json).status
            $col = if ($h -eq "ok") { "Green" } elseif ($h -eq "loading") { "Yellow" } else { "Red" }
            Write-Host "  $($pm[$port]) [$port]: $h" -ForegroundColor $col
        } catch {
            $sf = "$W\state_$port.txt"
            if ((Test-Path $sf) -and (Get-Content $sf -Raw).Trim() -eq "STOPPED") {
                Write-Host "  $($pm[$port]) [$port]: STOPPED (restarts on request)" -ForegroundColor Yellow
            } else {
                Write-Host "  $($pm[$port]) [$port]: NOT RUNNING" -ForegroundColor Red
            }
        }
    }
    $wd = Get-WmiObject Win32_Process | Where-Object { $_.Name -eq "powershell.exe" -and $_.CommandLine -match "watchdog" }
    if ($wd) { Write-Host "  Watchdog: RUNNING (PID $($wd.ProcessId -join ' '))" -ForegroundColor Green }
    else      { Write-Host "  Watchdog: NOT RUNNING" -ForegroundColor Yellow }
    if (Test-Path "$W\watchdog.log") {
        Write-Host "  Watchdog log (last 5):" -ForegroundColor Gray
        Get-Content "$W\watchdog.log" -Tail 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
    if (Test-Path "$W\run.ps1") {
        $run = Get-Content "$W\run.ps1" -Raw
        if ($run -match "--model\s+(\S+)")    { Write-Host "  Model:   $($Matches[1])" -ForegroundColor Cyan }
        if ($run -match "--ctx-size\s+(\d+)") { Write-Host "  Context: $($Matches[1]) tokens" -ForegroundColor Cyan }
    }
}

# =============================================================================
# MODEL CATALOG
# =============================================================================
function Get-CtxSize($v) {
    if ($v -ge 32000) { return 32768 }
    if ($v -ge 14000) { return 16384 }
    if ($v -ge 9000)  { return 16384 }
    if ($v -ge 6000)  { return 8192 }
    return 4096
}

function Select-BestModel($vram, $mode) {
    if ($mode -eq "code") {
        return [PSCustomObject]@{ name="kodify-2b-q8"; file="kodify-2b-q8.gguf"; minVram=3200
            url="https://huggingface.co/mradermacher/Kodify-Nano-2.0-GGUF/resolve/main/Kodify-Nano-2.0.Q8_0.gguf" }
    }
    $res = @{ chat=0; voice=512; doc=1500; full=2000 }
    $budget = $vram - 1200 - ($res[$mode] ?? 0)
    $cat = @(
        [PSCustomObject]@{name="t-pro-32b-q8";   file="t-pro-32b-q8.gguf";   minVram=36000;url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q8_0.gguf"}
        [PSCustomObject]@{name="t-pro-32b-q5";   file="t-pro-32b-q5.gguf";   minVram=23000;url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q5_K_M.gguf"}
        [PSCustomObject]@{name="t-pro-32b-q4";   file="t-pro-32b-q4.gguf";   minVram=19000;url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q4_K_M.gguf"}
        [PSCustomObject]@{name="saiga-nem12-q8"; file="saiga-nem12-q8.gguf"; minVram=14500;url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q8_0.gguf"}
        [PSCustomObject]@{name="saiga-gem12-q8"; file="saiga-gem12-q8.gguf"; minVram=14500;url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q8_0.gguf"}
        [PSCustomObject]@{name="saiga-nem12-q6"; file="saiga-nem12-q6.gguf"; minVram=11500;url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q6_K.gguf"}
        [PSCustomObject]@{name="saiga-gem12-q6"; file="saiga-gem12-q6.gguf"; minVram=11500;url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q6_K.gguf"}
        [PSCustomObject]@{name="t-lite-8b-q8";   file="t-lite-8b-q8.gguf";   minVram=10000;url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q8_0.gguf"}
        [PSCustomObject]@{name="yagpt-8b-q8";    file="yagpt-8b-q8.gguf";    minVram=10000;url="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q8_0.gguf"}
        [PSCustomObject]@{name="qvikhr-8b-q8";   file="qvikhr-8b-q8.gguf";   minVram=10000;url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruction-GGUF/resolve/main/QVikhr-3-8B-Instruction-Q8_0.gguf"}
        [PSCustomObject]@{name="saiga-nem12-q5"; file="saiga-nem12-q5.gguf"; minVram=9800;url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q5_K_M.gguf"}
        [PSCustomObject]@{name="saiga-gem12-q5"; file="saiga-gem12-q5.gguf"; minVram=9800;url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q5_K_M.gguf"}
        [PSCustomObject]@{name="t-lite-8b-q6";   file="t-lite-8b-q6.gguf";   minVram=8200;url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q6_K.gguf"}
        [PSCustomObject]@{name="saiga-nem12-q4"; file="saiga-nem12-q4.gguf"; minVram=8300;url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q4_K_M.gguf"}
        [PSCustomObject]@{name="saiga-gem12-q4"; file="saiga-gem12-q4.gguf"; minVram=8300;url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q4_K_M.gguf"}
        [PSCustomObject]@{name="qvikhr-8b-q5";   file="qvikhr-8b-q5.gguf";   minVram=6800;url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruction-GGUF/resolve/main/QVikhr-3-8B-Instruction-Q5_0.gguf"}
        [PSCustomObject]@{name="t-lite-8b-q5";   file="t-lite-8b-q5.gguf";   minVram=6600;url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q5_K_M.gguf"}
        [PSCustomObject]@{name="qvikhr-4b-q8";   file="qvikhr-4b-q8.gguf";   minVram=5800;url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q8_0.gguf"}
        [PSCustomObject]@{name="t-lite-8b-q4";   file="t-lite-8b-q4.gguf";   minVram=5600;url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q4_K_M.gguf"}
        [PSCustomObject]@{name="yagpt-8b-q4";    file="yagpt-8b-q4.gguf";    minVram=5600;url="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q4_K_M.gguf"}
        [PSCustomObject]@{name="qvikhr-8b-q4";   file="qvikhr-8b-q4.gguf";   minVram=5700;url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruction-GGUF/resolve/main/QVikhr-3-8B-Instruction-Q4_K_M.gguf"}
        [PSCustomObject]@{name="qvikhr-4b-q5";   file="qvikhr-4b-q5.gguf";   minVram=4300;url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q5_0.gguf"}
        [PSCustomObject]@{name="qvikhr-4b-q4";   file="qvikhr-4b-q4.gguf";   minVram=3800;url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q4_K_M.gguf"}
        [PSCustomObject]@{name="qvikhr-1b-q8";   file="qvikhr-1b-q8.gguf";   minVram=2600;url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruction-GGUF/resolve/main/QVikhr-3-1.7B-Instruction-Q8_0.gguf"}
        [PSCustomObject]@{name="qvikhr-1b-q4";   file="qvikhr-1b-q4.gguf";   minVram=1800;url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruction-GGUF/resolve/main/QVikhr-3-1.7B-Instruction-Q4_K_M.gguf"}
    )
    $best = $cat | Where-Object { $_.minVram -le $budget } | Select-Object -First 1
    if (!$best) { $best = $cat | Select-Object -Last 1 }
    return $best
}

# =============================================================================
# START SERVICE  (fire-and-forget, show crash within 4s)
# =============================================================================
function Start-Svc($pyPath, $logPath, $errPath) {
    Remove-Item $errPath -ErrorAction SilentlyContinue
    Start-Process python -ArgumentList $pyPath -WindowStyle Hidden `
        -RedirectStandardOutput $logPath -RedirectStandardError $errPath
    Start-Sleep -s 4
    $tail  = Get-Content $errPath -Tail 5 -ErrorAction SilentlyContinue
    $crash = $tail | Where-Object { $_ -match "LOAD_ERROR|ImportError|ModuleNotFoundError|No module" }
    if ($crash) { Write-Host "  CRASH: $($crash[0])" -ForegroundColor Red; return $false }
    return $true
}

# =============================================================================
# DEPLOY
# =============================================================================
function Invoke-Deploy {
    $t0  = Get-Date
    $TAG = "b5248"
    Write-Host "--- LLM DEPLOY v15.0 | Mode=$Mode | GPUs=$Gpus ---" -ForegroundColor Cyan
    Write-Host "  All cached steps skipped -- 2nd run takes ~20s" -ForegroundColor Gray

    Get-Process | Where-Object { $_.Name -match "llama" } | Stop-Process -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null

    # [1] Python
    Write-Host "[1/7] Python..." -ForegroundColor Cyan
    $pv = & python --version 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "  Python not found!" -ForegroundColor Red; exit 1 }
    Write-Host "  $pv" -ForegroundColor Green

    # [2] CUDA DLLs
    Write-Host "[2/7] CUDA DLLs..." -ForegroundColor Cyan
    if ((Get-Stamp "cuda_dlls") -ne $TAG) {
        Write-Host "  Installing nvidia runtime DLLs..." -ForegroundColor Gray
        & python -m pip install --quiet nvidia-cuda-runtime-cu12 nvidia-cublas-cu12 nvidia-cudnn-cu12 2>&1 | Out-Null
        Set-Stamp "cuda_dlls" $TAG
        Write-Host "  Done" -ForegroundColor Green
    } else { Write-Host "  Cached" -ForegroundColor Green }

    # [3] Engine
    Write-Host "[3/7] Engine..." -ForegroundColor Cyan
    $binDir   = "$W\bin"
    $llamaExe = "$binDir\llama-server.exe"
    if ((Get-Stamp "engine") -ne $TAG -or !(Test-Path $llamaExe)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        Write-Host "  Downloading llama.cpp $TAG ..." -ForegroundColor Gray
        $zipUrl = "https://github.com/ggerganov/llama.cpp/releases/download/$TAG/llama-$TAG-bin-win-cuda-cu12.2.0-x64.zip"
        curl.exe -L --retry 3 --max-time 300 --progress-bar $zipUrl -o "$W\eng.zip"
        Expand-Archive "$W\eng.zip" $binDir -Force
        Remove-Item "$W\eng.zip" -ErrorAction SilentlyContinue
        Set-Stamp "engine" $TAG
        Write-Host "  Installed" -ForegroundColor Green
    } else { Write-Host "  Cached ($TAG)" -ForegroundColor Green }

    # [4] Engine test
    Write-Host "[4/7] Engine test..." -ForegroundColor Cyan
    if ((Get-Stamp "engine_type") -ne "cuda_$TAG") {
        $tv = & "$llamaExe" --version 2>&1
        $et = if ($tv -match "CUDA") { "CUDA" } elseif ($tv -match "Vulkan") { "Vulkan" } else { "CPU" }
        Set-Stamp "engine_type" "cuda_$TAG"
        Write-Host "  Type: $et" -ForegroundColor Green
    } else { Write-Host "  Cached (CUDA)" -ForegroundColor Green }

    # [5] GPUs
    Write-Host "[5/7] GPUs..." -ForegroundColor Cyan
    $devOut = & "$llamaExe" --list-devices 2>&1
    $gpuMiB = @()
    foreach ($ln in $devOut) {
        if ($ln -match "CUDA\d+.*?(\d+) MiB") { $gpuMiB += [int]$Matches[1] }
        if ($ln -match "ggml_cuda_init:|CUDA\d+:") { Write-Host "  $ln" -ForegroundColor Gray }
    }
    $nGpu = if ($Gpus -eq "all") { $gpuMiB.Count } elseif ($Gpus -match "^\d+$") { [int]$Gpus } else { 1 }
    if ($nGpu -gt $gpuMiB.Count -or $nGpu -lt 1) { $nGpu = [Math]::Max(1, $gpuMiB.Count) }
    $totalVram = ($gpuMiB[0..($nGpu-1)] | Measure-Object -Sum).Sum
    $gpuArgs   = if ($nGpu -gt 1) { "-ngl 999 -ts " + ($gpuMiB[0..($nGpu-1)] -join ",") } else { "-ngl 999" }
    Write-Host "  $nGpu GPU(s) | VRAM: $totalVram MiB" -ForegroundColor Green

    # [6] Model
    Write-Host "[6/7] Model..." -ForegroundColor Cyan
    $m    = Select-BestModel $totalVram $Mode
    $ctx  = Get-CtxSize $totalVram
    Write-Host "  Selected: $($m.name) | ctx: $ctx" -ForegroundColor Green
    $mPath = "$W\models\$($m.file)"
    if ((Test-Path $mPath) -and (Get-Item $mPath).Length -gt 50MB) {
        Write-Host "  Cached: $($m.name) ($([math]::Round((Get-Item $mPath).Length/1MB)) MB)" -ForegroundColor Green
    } else {
        $sz = Download-Model $m.url $mPath
        if ($sz -eq 0) {
            Write-Host "  Download failed, trying qvikhr-4b-q4 fallback..." -ForegroundColor Red
            $mPath = "$W\models\qvikhr-4b-q4.gguf"
            $sz = Download-Model "https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q4_K_M.gguf" $mPath
            if ($sz -eq 0) { Write-Host "  All downloads failed." -ForegroundColor Red; exit 1 }
            $m = [PSCustomObject]@{ name="qvikhr-4b-q4" }
        }
    }

    # [7] Services
    Write-Host "[7/7] Services..." -ForegroundColor Cyan
    $doAsr   = $Mode -in @("voice","full")
    $doOcr   = $Mode -in @("doc","full")
    $doEmbed = $Mode -in @("doc","full")

    $runScript = "& '$llamaExe' --model '$mPath' $gpuArgs --ctx-size $ctx --port 8010 --host 0.0.0.0 --log-disable"
    [System.IO.File]::WriteAllText("$W\run.ps1", $runScript)
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$W\run.ps1`"" -WindowStyle Hidden
    Write-Host "  LLM starting on :8010" -ForegroundColor Green

    if ($doAsr) {
        Write-Host "  [ASR] gigaam..." -ForegroundColor Yellow
        Pip-Cached "gigaam" "pip_gigaam" "ok"
        Write-B64Service $ASR_B64 "$W\asr_service.py" @{ "%%IDLE_ASR%%" = "$IDLE_ASR" }
        if (Start-Svc "$W\asr_service.py" "$W\asr.log" "$W\asr_err.log") {
            "READY" | Set-Content "$W\state_8011.txt"
            Write-Host "  [ASR] started :8011" -ForegroundColor Green
        }
    }

    if ($doOcr) {
        Write-Host "  [OCR] surya-ocr>=0.4,<0.7 ..." -ForegroundColor Yellow
        Pip-Cached "surya-ocr>=0.4,<0.7" "pip_surya" "0.6"
        Write-B64Service $OCR_B64 "$W\ocr_service.py" @{ "%%IDLE_OCR%%" = "$IDLE_OCR" }
        if (Start-Svc "$W\ocr_service.py" "$W\ocr.log" "$W\ocr_err.log") {
            "READY" | Set-Content "$W\state_8013.txt"
            Write-Host "  [OCR] started :8013 (loading models in bg)" -ForegroundColor Green
        }
    }

    if ($doEmbed) {
        Write-Host "  [Embed] transformers..." -ForegroundColor Yellow
        Pip-Cached "transformers" "pip_transformers" "ok"
        Write-B64Service $EMBED_B64 "$W\embed_service.py" @{ "%%IDLE_EMBED%%" = "$IDLE_EMBED" }
        if (Start-Svc "$W\embed_service.py" "$W\embed.log" "$W\embed_err.log") {
            "READY" | Set-Content "$W\state_8014.txt"
            Write-Host "  [Embed] started :8014 (loading model in bg)" -ForegroundColor Green
        }
    }

    # Watchdog
    $wdSrc = "$W\watchdog_src.ps1"
    if (Test-Path $wdSrc) {
        Copy-Item $wdSrc "$W\watchdog.ps1" -Force
        Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$W\watchdog.ps1`" -Mode $Mode" -WindowStyle Hidden
    }

    $elapsed = [int]((Get-Date) - $t0).TotalSeconds
    Write-Host ""
    Write-Host "SUCCESS - LLM Orchestrator v15.0  (${elapsed}s)" -ForegroundColor Green
    Write-Host "  Mode:    $Mode"           -ForegroundColor Cyan
    Write-Host "  Model:   $($m.name)"     -ForegroundColor Cyan
    Write-Host "  VRAM:    $totalVram MiB" -ForegroundColor Cyan
    Write-Host "  Context: $ctx tokens"    -ForegroundColor Cyan
    Write-Host "  LLM:     http://localhost:8010/v1" -ForegroundColor Cyan
    if ($doAsr)   { Write-Host "  ASR:     http://localhost:8011" -ForegroundColor Cyan }
    if ($doOcr)   { Write-Host "  OCR:     http://localhost:8013" -ForegroundColor Cyan }
    if ($doEmbed) { Write-Host "  Embed:   http://localhost:8014" -ForegroundColor Cyan }
    Write-Host ""
    Write-Host "  TIP: winget install aria2.aria2  -- 4-8x faster downloads" -ForegroundColor Gray
    Write-Host "  Stop:   powershell -EP Bypass -File win_deploy.ps1 --stop" -ForegroundColor Gray
    Write-Host "  Status: powershell -EP Bypass -File win_deploy.ps1 --status" -ForegroundColor Gray
}

# =============================================================================
# MAIN
# =============================================================================
switch ($Action) {
    "--stop"    { Invoke-Stop }
    "--status"  { Invoke-Status }
    "--restart" { Invoke-Stop; Start-Sleep -s 2; Invoke-Deploy }
    default     { Invoke-Deploy }
}
