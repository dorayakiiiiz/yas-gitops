# generate-values.ps1
# Script tự động tạo các file values cấu hình theo môi trường (dev, staging, v.v.)
# Chạy script này tại thư mục gốc của repo yas-gitops.

$CHARTS_DIR = "k8s\charts"

if (!(Test-Path $CHARTS_DIR)) {
    Write-Host "Error: k8s\charts directory not found. Please ensure you are running this script in the root directory of yas-gitops." -ForegroundColor Red
    exit 1
}

Write-Host "Generating environment configuration files..." -ForegroundColor Cyan

Get-ChildItem -Path $CHARTS_DIR -Directory | ForEach-Object {
    $svcPath = $_.FullName
    $valPath = Join-Path $svcPath "values.yaml"
    
    if (Test-Path $valPath) {
        $c = Get-Content $valPath -Raw
        
        # Tạo cấu hình cho môi trường DEV
        $devPath = Join-Path $svcPath "values-dev.yaml"
        $c -replace "\.yas\.local\.com", ".dev.local.com" -replace "\.yas\.svc\.cluster\.local", ".dev.svc.cluster.local" | Out-File -Encoding utf8 $devPath
        
        # Tạo cấu hình cho môi trường STAGING
        $stagingPath = Join-Path $svcPath "values-staging.yaml"
        $c -replace "\.yas\.local\.com", ".staging.local.com" -replace "\.yas\.svc\.cluster\.local", ".staging.svc.cluster.local" | Out-File -Encoding utf8 $stagingPath
    }
}

Write-Host "Successfully generated values-dev.yaml and values-staging.yaml for all Charts!" -ForegroundColor Green
Write-Host "Don't forget to git add, commit, and push to the main branch of yas-gitops!" -ForegroundColor Yellow
