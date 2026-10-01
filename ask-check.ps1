# ask-check.ps1
Write-Host "Checking Ollama status..." -ForegroundColor Cyan

try {
    $models = (Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -Method Get).models.name
    Write-Host "[OK] Ollama server is running." -ForegroundColor Green
    Write-Host "Available models:"
    foreach ($m in $models) { Write-Host " - $m" }
} catch {
    Write-Host "[FAIL] Ollama is down or throwing errors." -ForegroundColor Red
    Write-Host "Try restarting it: Stop-Process -Name 'ollama' -Force; ollama serve" -ForegroundColor Yellow
}