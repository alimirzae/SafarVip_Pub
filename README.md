# SafarVip — بسته به‌روزرسانی برنامه

این مخزن عمومی، آخرین DLL نهایی برنامه Safar و اسکریپت امن به‌روزرسانی IIS را نگهداری می‌کند.

## آخرین نسخه

آخرین بسته از صفحه [Releases](https://github.com/alimirzae/SafarVip_Pub/releases/tag/latest) در دسترس است:

- `Safar-application-dlls.zip`: فقط DLLهای متعلق به خود برنامه (`Safar.dll` و در صورت تولید `Safar.Views.dll`)
- `Update-NewSafarVip.ps1`: اسکریپت دریافت و نصب خودکار روی IIS

این بسته به DLLهای جانبی مانند Stimulsoft، BotDetect و کتابخانه‌های گزارش‌گیری دست نمی‌زند.

## نصب یا به‌روزرسانی روی سرور

PowerShell را با دسترسی Administrator باز کنید و اجرا کنید:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Invoke-WebRequest `
  -Uri "https://github.com/alimirzae/SafarVip_Pub/raw/main/Update-NewSafarVip.ps1" `
  -OutFile ".\Update-NewSafarVip.ps1"

.\Update-NewSafarVip.ps1 -IisSiteName "new.safar.vip"
```

آزمایش بدون جایگزینی DLLها:

```powershell
.\Update-NewSafarVip.ps1 -IisSiteName "new.safar.vip" -WhatIf
```

اسکریپت مسیر سایت و Application Pool را از IIS پیدا می‌کند، از DLL فعلی نسخه پشتیبان می‌گیرد، فقط DLL برنامه را جایگزین می‌کند و Application Pool را دوباره راه‌اندازی می‌کند.

نسخه پشتیبان پیش‌فرض در `C:\SafarDeployBackups` ذخیره می‌شود.

## نیازمندی‌های سرور

- Windows Server و IIS
- ASP.NET Core Hosting Bundle سازگار با .NET 8
- PowerShell با دسترسی Administrator
- دسترسی خروجی HTTPS به GitHub

## نکته امنیتی

سورس اصلی به دلیل وجود تنظیمات محرمانه قدیمی در تاریخچه پروژه در مخزن خصوصی نگهداری می‌شود. این مخزن عمومی فقط خروجی قابل استقرار و ابزار به‌روزرسانی را ارائه می‌کند.
