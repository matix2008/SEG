# Проверка клиента SEG без full-tunnel AmneziaWG

Дополнение к пункту 42 плана. Серверная часть проверена через туннель `herman-wk1`; эта инструкция проверяет то, что туннель искажает: выход клиента из обычной сети, маршрутизацию selected-трафика, DNS и fail-closed. Два варианта на выбор, можно выполнить оба (порядок: часть 0 → часть A и/или B → часть D; часть C выполняется в ходе A/B, пока клиент подключён):

- **часть A** — компьютер с Windows 11;
- **часть B** — телефон на Android.

Инструкция рассчитана на чистое устройство: что скачать, откуда, как проверить файл, как установить и в каком порядке действовать. Знание проекта не требуется, но часть 0, часть C и часть D выполняются на ноутбуке проекта (где лежит каталог `SEG`).

## Значения, которые используются ниже

| Обозначение | Значение | Что это |
|---|---|---|
| `<IP_VPS1>` | `65.20.77.164` | `seg-exit`: адрес, с которым selected-ресурсы выходят в Интернет |
| `<IP_VPS2>` | `77.232.132.91` | `seg-gateway`: сюда подключается клиент (порт 443) |
| `X` | узнаётся в шаге 1 | внешний адрес вашей сети без VPN |

Значения берутся из `servers.txt`. Если пара узлов заменена, подставьте актуальные.

## Что нужно и что произойдёт

- Рабочий VPN на проверяемом устройстве на время проверки **отключается**: на Windows клиент SEG и full-tunnel AmneziaWG несовместимы (kill-switch блокирует `sing-box`), на Android одновременно работает только один VPN. Другие VPN (Hiddify и т. п.) тоже отключите.
- Для каждого устройства создаётся отдельный тестовый клиент (свой UUID); после проверки он удаляется (часть D).
- Профиль клиента содержит UUID и параметры REALITY. Передавайте его только на проверяемое устройство, по кабелю или флешкой, не в мессенджерах, почте и облаке; после проверки удалите.

## Часть 0. Подготовка на ноутбуке проекта

Каталог проекта: `C:\Разное\VPN\SEG`. Туннель `herman-wk1` здесь можно оставить включённым: ноутбук ходит на VPS через него.

1. Убедитесь, что пара узлов в порядке:

   ```powershell
   cd "C:\Разное\VPN\SEG"
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-servers.ps1 -Mode SEG all -Check
   ```

   Ожидание: `GATEWAY=READY`, `EXIT=READY`, `BACKHAUL=UP`, `HANDSHAKE=FRESH`, `FAIL_CLOSED=OK`, `SECURITY=OK`, код выхода 0.

2. Создайте тестовых клиентов (для тех частей, которые будете выполнять):

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\add-client.ps1 -Mode SEG chk-win11
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\add-client.ps1 -Mode SEG chk-android
   ```

   Каждая команда создаёт запись `clients\seg\ИМЯ.json` и профиль `clients\generated\seg\ИМЯ.json`.

3. Добавьте UUID на VPS2 (иначе сервер клиента не примет):

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-servers.ps1 -Mode SEG all
   ```

   Что произойдёт: `sync` всегда проходит все этапы подряд (`upgrade`, `bootstrap`, hardening, `snapshot`, fail-closed, маршрутизация, backhaul, egress, `sing-box`, итоговая проверка) и пишет много строк, в том числе `apt-get`; это не переустановка. На готовой паре узлы не перезагружаются и не переустанавливаются, пакеты уже «newest version», настройки fail-closed, backhaul и egress «already current». Меняется только `sing-box` на VPS2 (новые UUID, перезапуск службы), а также перезапускается Fail2Ban. Прогон занимает около 5 минут (из них около минуты копируется пакет `sing-box`). Ожидание: «SEG pair synchronized successfully». Текущие подключения клиентов SEG на время перезапуска `sing-box` прервутся.

4. Проверьте профили:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\make-client-config.ps1 -Mode SEG chk-win11
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\make-client-config.ps1 -Mode SEG chk-android
   ```

   Ожидание: строка `The profile of ИМЯ is current (seg-list version 1)`. Скрипт спросит «The profile is current. Recreate it anyway? [y/N]»: отвечайте **N** (ничего не меняется, код 0); «y» перезапишет профиль теми же данными, и копию на устройстве придётся заменить.

5. Только для Android: сделайте копию профиля без строки `log.output` (на телефоне файл журнала по относительному пути не нужен, журнал смотрят в приложении). Копия кладётся в отдельный каталог `clients\mobile\` (закрыт `.gitignore`): в `clients\generated\seg\` её класть нельзя, `-Check` посчитает её профилем без записи клиента и вернёт код 2.

   ```powershell
   New-Item -ItemType Directory .\clients\mobile -Force | Out-Null
   $p = [IO.File]::ReadAllText((Resolve-Path .\clients\generated\seg\chk-android.json), [Text.Encoding]::UTF8) | ConvertFrom-Json
   $p.log.PSObject.Properties.Remove('output')
   [IO.File]::WriteAllText("$PWD\clients\mobile\chk-android-mobile.json", ($p | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
   .\tools\sing-box.exe check -c .\clients\mobile\chk-android-mobile.json
   ```

   Ожидание: команда `check` ничего не выводит, код 0. Файл без BOM, UTF-8. На телефон передаётся `chk-android-mobile.json`.

6. Скопируйте файлы на устройства (USB-кабелем или флешкой):

   | Устройство | Что передать |
   |---|---|
   | Windows 11 | `clients\generated\seg\chk-win11.json` |
   | Android | `clients\mobile\chk-android-mobile.json` и APK из части B (шаг B2) |

---

## Часть A. Windows 11

Нужны: Windows 11 x64, учётная запись администратора, доступ в Интернет (без VPN), около 200 МБ места. Подойдёт любой компьютер, в том числе ноутбук проекта с отключённым `herman-wk1` (тогда после проверки включите его, шаг A11).

### A1. Подготовить каталог и скачать sing-box

Откройте **Терминал** или **Windows PowerShell** от имени администратора (правый щелчок по «Пуск» → «Терминал (администратор)»). Все команды части A выполняйте в этом окне, если не сказано иное.

```powershell
New-Item -ItemType Directory C:\seg-check -Force | Out-Null
Set-Location C:\seg-check
Invoke-WebRequest -UseBasicParsing -Uri https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-windows-amd64.zip -OutFile sing-box.zip
```

Источник: официальный релиз <https://github.com/SagerNet/sing-box/releases/tag/v1.14.4>. Нужен файл `sing-box-1.14.4-windows-amd64.zip` (не `legacy-windows-7`). Можно скачать его и браузером с этой страницы (раздел Assets) и положить в `C:\seg-check\sing-box.zip`.

### A2. Проверить архив

```powershell
(Get-FileHash .\sing-box.zip -Algorithm SHA256).Hash.ToLower()
```

Должно быть ровно: `99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df`. Если значение другое, удалите файл, скачайте заново и не продолжайте, пока хэш не совпадёт.

### A3. Распаковать и проверить файлы

```powershell
Expand-Archive .\sing-box.zip -DestinationPath .\unpacked -Force
Copy-Item .\unpacked\sing-box-1.14.4-windows-amd64\sing-box.exe, .\unpacked\sing-box-1.14.4-windows-amd64\libcronet.dll .
Get-ChildItem .\sing-box.exe, .\libcronet.dll | Unblock-File
Get-FileHash .\sing-box.exe, .\libcronet.dll -Algorithm SHA256 | Format-Table Hash, @{n='File';e={Split-Path $_.Path -Leaf}} -AutoSize
.\sing-box.exe version
```

Ожидание (регистр букв в хэше не важен):

| Файл | SHA-256 |
|---|---|
| `sing-box.exe` | `8f30682ee198855440d2a7fe070d5d3653793b2d01bb8c85eea88f93bbe7c8b9` |
| `libcronet.dll` | `3217c6260fbca5f16072e0b79735742f40109a63bb0ff88fd6b96dd6b54a2928` |

`sing-box.exe version` показывает `sing-box version 1.14.4`. `libcronet.dll` должен лежать рядом с `sing-box.exe`.

Если антивирус или SmartScreen блокирует `sing-box.exe`: файл официальный, поэтому сначала убедитесь, что хэш совпадает, и только после этого разрешите запуск.

### A4. Положить профиль и проверить его

Скопируйте `chk-win11.json` (часть 0, шаг 6) в `C:\seg-check`, затем:

```powershell
.\sing-box.exe check -c .\chk-win11.json
```

Ожидание: пусто, без ошибок. (Профиль не нужно открывать и редактировать.)

### A5. Условия перед запуском

```powershell
Get-Service 'AmneziaWGTunnel*' | Where-Object Status -eq 'Running'
Get-Process sing-box, hiddify, Hiddify -ErrorAction SilentlyContinue
Test-NetConnection 77.232.132.91 -Port 443 | Select-Object TcpTestSucceeded
```

Первые две команды ничего не должны вывести (нет работающих VPN-клиентов), третья даёт `TcpTestSucceeded : True`. Если `False` — сеть не пропускает 443 к VPS2: проверка невозможна, смените сеть.

### A6. Шаг 1: базовая линия (клиент ещё не запущен)

Команды сохраняют значения в переменные и в файлы `x.txt` и `real.txt` (чтобы второе окно из A7 прочитало их само, без ручной подстановки) и печатают их с подписями:

```powershell
$X = (curl.exe -4 -s https://api.ipify.org).Trim()
$REAL = (Resolve-DnsName chatgpt.com -Type A -DnsOnly | Where-Object Type -eq 'A' | Select-Object -First 1).IPAddress
Set-Content .\x.txt $X
Set-Content .\real.txt $REAL
"X (адрес вашей сети) = $X"
"REAL (настоящий IPv4 chatgpt.com) = $REAL"
```

`$X` не должен совпадать с `<IP_VPS1>` и `<IP_VPS2>`. `$REAL` не должен быть адресом из `198.18.0.0/15`. Запишите оба значения. Выполнять нужно до запуска клиента (шаг A7): с работающим клиентом `$REAL` окажется FakeIP-адресом.

### A7. Шаг 2: запуск клиента

```powershell
.\sing-box.exe run -c .\chk-win11.json
```

Окно оставьте открытым, клиент работает, пока оно открыто. В нём ничего не печатается: журнал идёт в файл `client-tun.log` рядом. Откройте **второе** окно PowerShell (обычное, не администратора) и выполните:

```powershell
Set-Location C:\seg-check
$X = (Get-Content .\x.txt).Trim()
$REAL = (Get-Content .\real.txt).Trim()
"X = $X; REAL = $REAL"
Get-NetAdapter seg-tun | Select-Object Name, Status
Select-String -Path .\client-tun.log -Pattern 'ERROR|FATAL' | Where-Object { $_.Line -notmatch 'outbound/direct\[direct\]' } | Select-Object -First 5
```

Ожидание: адаптер `seg-tun` со статусом `Up`; последняя команда не выводит ничего. Ошибки вида `outbound/direct[direct]: dial tcp ...: i/o timeout` в журнале допустимы: это прямые соединения других программ этого компьютера к посторонним адресам (не из `seg-list`), к SEG они не относятся. Ошибки с `vless`, `reality`, `seg` или `authentication` недопустимы. Остальные шаги выполняйте во втором окне.

### A8. Шаги 3–6: маршрутизация и DNS

```powershell
# 3. ресурс из seg-list: ожидается ip=<IP_VPS1>
curl.exe -4 -s https://chatgpt.com/cdn-cgi/trace | Select-String '^ip='

# 4. ресурс вне seg-list: ожидается X (адрес из шага 1)
"X = $X"
curl.exe -4 -s https://api.ipify.org

# 5. DNS: selected-домен получает FakeIP 198.18.x.x, AAAA нет, прямой домен резолвится по-настоящему
Resolve-DnsName chatgpt.com -Type A | Select-Object Name, IPAddress
Resolve-DnsName chatgpt.com -Type AAAA -ErrorAction SilentlyContinue
Resolve-DnsName example.com -Type A | Select-Object Name, IPAddress
```

Ожидание: шаг 3 даёт `ip=65.20.77.164`; шаг 4 даёт `X`, а не `<IP_VPS1>` и не `<IP_VPS2>`; в шаге 5 первый домен получает адрес `198.18.x.x`, AAAA для него не возвращается (пустой ответ или ошибка), у `example.com` настоящий адрес (не `198.18.x.x`).

```powershell
# 6. запрос к selected-ресурсу по настоящему IP (без FakeIP): домен определяется по SNI, выход через VPS1
"REAL = $REAL"
curl.exe -4 -s --resolve "chatgpt.com:443:$REAL" https://chatgpt.com/cdn-cgi/trace | Select-String '^ip='
```

Ожидание: `REAL` — настоящий адрес chatgpt.com (не `$X`, не `198.18.x.x`, не пусто), ответ `ip=65.20.77.164`. Если ответ пустой, сначала убедитесь, что `$REAL` задан правильно.

### A9. Шаги 7–8: проверки с ноутбука проекта

Пока клиент работает, выполните часть C (журнал VPS2 и fail-closed). Для клиента Windows используйте имя `chk-win11`.

### A10. Шаг 9: остановка

В **первом** окне (где работает `sing-box`) нажмите `Ctrl+C`. Затем:

```powershell
Get-NetAdapter seg-tun -ErrorAction SilentlyContinue
curl.exe -4 -s https://api.ipify.org
```

Ожидание: адаптера `seg-tun` нет, адрес снова `X`.

### A11. Очистка и возврат

```powershell
Set-Location C:\
Remove-Item C:\seg-check -Recurse -Force
```

Если проверка шла на ноутбуке проекта, включите `herman-wk1` в приложении AmneziaWG и убедитесь, что `Get-Service 'AmneziaWGTunnel*'` показывает `Running`. Профиль удалите и с флешки.

---

## Часть B. Android

> **Статус:** часть B не проверялась на устройстве. На Windows 11 проверка выполнена полностью; для Android принято считать её дублирующей (правила маршрутизации и DNS в профиле те же), а пошаговые действия (меню SFA, импорт профиля) описаны по документации и могут отличаться на вашем телефоне. Профиль для Android проверен только командой `sing-box check`.

Нужен телефон на Android (для Android 5 в релизе есть отдельные сборки `legacy-android-5`, на более новых используйте обычную сборку), доступ в Интернет (Wi-Fi или мобильная сеть), кабель USB и ноутбук для проверки файла.

### B1. Подготовить телефон

1. Отключите любой другой VPN (AmneziaWG, Hiddify, корпоративный и т. п.): «Настройки → Сеть и Интернет → VPN» не должен показывать подключённых.
2. Для проверки DNS отключите защищённый DNS: «Настройки → Сеть и Интернет → Частный DNS» → «Выключено» (названия пунктов зависят от производителя). В Chrome: «Настройки → Конфиденциальность и безопасность → Использовать безопасный DNS» → выключить. Иначе DoT/DoH обходит перехват DNS в `sing-box`; в этом случае домен всё равно определяется по SNI, но IPv6-соединение может пойти мимо VPN, и проверка станет неоднозначной.

### B2. Скачать и проверить приложение (на ноутбуке)

Приложение: **sing-box for Android (SFA)**, официальный клиент проекта. Версия должна совпадать с эталонной, 1.14.4.

1. Откройте <https://github.com/SagerNet/sing-box/releases/tag/v1.14.4>, раздел Assets, скачайте `SFA-1.14.4-universal.apk` (универсальный, подходит для любой архитектуры; около 127 МБ).
2. Проверьте файл:

   ```powershell
   (Get-FileHash "$env:USERPROFILE\Downloads\SFA-1.14.4-universal.apk" -Algorithm SHA256).Hash.ToLower()
   ```

   Ожидание: `382cd451a135b4da7dbdfb031dcc34046b2feb0cb32d3eb69655b20bd376d3f9`. Если не совпадает, скачайте заново.

Если предпочитаете магазин: Google Play (`io.nekohasekai.sfa`) или F-Droid (`io.nekohasekai.sfa`). Версия там может отличаться от 1.14.4; для проверки это допустимо, но зафиксируйте номер версии из приложения («Настройки → О программе») в таблице результатов.

### B3. Перенести файлы на телефон

1. Подключите телефон к ноутбуку кабелем, на телефоне выберите режим «Передача файлов» (MTP).
2. Скопируйте на телефон в папку `Download` два файла: `SFA-1.14.4-universal.apk` и `chk-android-mobile.json`.

### B4. Установить приложение

1. На телефоне откройте файловый менеджер → `Download` → `SFA-1.14.4-universal.apk`.
2. Android спросит разрешение на установку из этого источника («Разрешить установку из этого источника» для файлового менеджера): разрешите.
3. Нажмите «Установить», затем «Открыть». После проверки разрешение можно отозвать (шаг B11).

### B5. Импортировать профиль

В приложении sing-box:

1. Вкладка **Profiles** (Профили) → кнопка **+** (новый профиль).
2. Заполните: **Name** — `chk-android`; **Type** — `Local`; **Source** — `Import` (импорт из файла).
3. Выберите файл `chk-android-mobile.json` в `Download`. Нажмите **Create**.
4. Если приложение сообщает об ошибке разбора профиля, не редактируйте его вручную: сохраните текст ошибки и перейдите к разделу «Если что-то не прошло».

### B6. Шаг 1: базовая линия (клиент ещё не запущен)

В Chrome откройте <https://api.ipify.org> и запишите адрес `X` (это адрес вашей сети: Wi-Fi или оператора). Он не должен совпадать с `<IP_VPS1>` и `<IP_VPS2>`.

### B7. Шаг 2: запуск клиента

1. Вкладка **Dashboard**: убедитесь, что выбран профиль `chk-android`.
2. Включите переключатель (кнопка запуска). Android покажет запрос «Подключение VPN» — подтвердите. В строке состояния появится значок ключа.
3. Откройте вкладку **Log** (Журнал). Ожидание: строки `started`, нет `ERROR`.

### B8. Шаги 3–4: маршрутизация

При включённом клиенте в Chrome (для чистоты результата используйте вкладку «Инкогнито» и обновляйте страницу):

| Шаг | Адрес | Ожидание |
|---|---|---|
| 3 | <https://chatgpt.com/cdn-cgi/trace> | в тексте `ip=65.20.77.164` (`<IP_VPS1>`) |
| 4 | <https://api.ipify.org> | адрес `X`, не `<IP_VPS1>` и не `<IP_VPS2>` |
| 4а | <https://api64.ipify.org> | если у вас есть IPv6: ваш обычный IPv6 (прямой трафик), не `<IP_VPS1>` |

Журнал sing-box в приложении подтверждает маршрутизацию (вкладка **Log**, сразу после шага 3): должна быть строка вида `outbound/vless[seg]: outbound connection to chatgpt.com:443`. Для шага 4 в журнале соединения с `api.ipify.org` идут через `outbound/direct`, не через `vless`.

Проверка DNS (шаг 5) и запроса по IP (шаг 6) на Android в приложении не видна: проведите их с Windows (часть A) или считайте подтверждёнными по пп. 35, 36 и 39 плана. Правила DNS и маршрутизации в профиле одинаковые.

### B9. Шаги 7–8: проверки с ноутбука проекта

Пока клиент включён, выполните часть C (журнал VPS2 и fail-closed). Имя клиента: `chk-android`. Для fail-closed на телефоне загрузите <https://chatgpt.com/cdn-cgi/trace> во вкладке «Инкогнито» (в ответ ничего не придёт, страница зависнет или выдаст ошибку); затем откройте <https://api.ipify.org> — прямой трафик продолжает работать.

### B10. Шаг 9: остановка

В приложении на вкладке **Dashboard** выключите переключатель, значок ключа в строке состояния должен исчезнуть. Откройте <https://api.ipify.org>: снова адрес `X`.

### B11. Очистка

1. В приложении: **Profiles** → профиль `chk-android` → удалить.
2. «Настройки → Приложения → sing-box → Удалить» (если не планируете им пользоваться).
3. Удалите из `Download` файлы `chk-android-mobile.json` и `SFA-1.14.4-universal.apk`.
4. Верните настройки: «Частный DNS» и «Безопасный DNS» в Chrome, запрет установки из неизвестных источников.

---

## Часть C. Проверки с ноутбука проекта (во время работы клиента)

Выполняется, пока клиент подключён (для Windows — после шага A8, для Android — после B8). Туннель `herman-wk1` на ноутбуке проекта можно оставить включённым.

### Шаг 7: клиент виден на VPS2, домен передан

Время в журнале VPS2 указано в UTC (Москва = UTC+3). Окно берите с запасом: проверка идёт не сразу после шага 3. Выполняйте на ноутбуке проекта:

```powershell
# входящие соединения клиента с именем домена
ssh root@77.232.132.91 "journalctl -u sing-box --since '-60min' --no-pager | grep -F chk-win11 | grep -F chatgpt.com | tail -5"

# исходящие на VPS1 (в строке нет имени клиента: соединения связаны номером в [...] со строкой inbound)
ssh root@77.232.132.91 "journalctl -u sing-box --since '-60min' --no-pager | grep -F 'outbound/direct[seg-out]' | grep -F chatgpt.com | tail -5"
```

(для телефона замените `chk-win11` на `chk-android`). Ожидание: в первой команде строки `inbound connection to chatgpt.com:443` от клиента (домен получен как имя, не как IP), во второй `outbound connection to chatgpt.com:443` через `seg-out`. Для прямого ресурса (`api.ipify.org`) строк быть не должно: он не доходил до VPS2. Если вывод пуст, проверьте, что шаг 3 выполнялся при включённом клиенте и что окно (`-60min`) охватывает его время.

### Шаг 8: fail-closed

Клиент подключён. Остановите backhaul на VPS2:

```powershell
ssh root@77.232.132.91 "systemctl stop awg-quick@awg-backhaul"
```

Теперь на устройстве три раза подряд (с интервалом несколько секунд) запросите selected-ресурс:

- Windows (во втором окне):

  ```powershell
  1..3 | ForEach-Object { curl.exe -4 -s -m 10 -o NUL -w "http=%{http_code}`n" https://chatgpt.com/cdn-cgi/trace; Start-Sleep 3 }
  ```

- Android: <https://chatgpt.com/cdn-cgi/trace> во вкладке «Инкогнито».

Ожидание: ресурс **не открывается** (на Windows `http=000` три раза, то есть ответа нет), и ни разу не показывается `ip=77.232.132.91` (`<IP_VPS2>`). Прямой запрос (`https://api.ipify.org`) продолжает работать и показывает `X`. Затем подтвердите причину по журналу VPS2 (на ноутбуке проекта):

```powershell
ssh root@77.232.132.91 "journalctl -u sing-box --since '-10min' --no-pager | grep -F 'no route to host' | tail -3"
```

Ожидание: строки `dial tcp ...: connect: no route to host` через `outbound/direct[seg-out]` (backhaul остановлен, выхода на VPS1 нет, а запасного выхода через VPS2 нет). Счётчик drop-правила в таблице `seg_failclosed` может при этом остаться нулевым: соединение привязано к остановленному интерфейсу backhaul и до правила не доходит (само правило проверено в п. 38), по нему судить не нужно. Затем верните узлы:

```powershell
cd "C:\Разное\VPN\SEG"
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-servers.ps1 -Mode SEG all
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-servers.ps1 -Mode SEG all -Check
```

Ожидание: `BACKHAUL=UP`, `HANDSHAKE=FRESH`; на устройстве шаг 3 снова показывает `ip=65.20.77.164`. Если `sync` остановился на ошибке, повторите его: он идемпотентен.

---

## Часть D. Завершение: удалить тестовых клиентов

На ноутбуке проекта:

```powershell
cd "C:\Разное\VPN\SEG"
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\remove-client.ps1 -Mode SEG chk-win11
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\remove-client.ps1 -Mode SEG chk-android
Remove-Item .\clients\mobile -Recurse -Force -ErrorAction SilentlyContinue
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-servers.ps1 -Mode SEG all
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-servers.ps1 -Mode SEG all -Check
```

Ожидание: клиенты удалены, `sync` убирает их UUID с VPS2, `-Check` проходит (`OK`, код 0). До `sync` UUID остаются действующими.

## Таблица результата

Заполните «Факт» и сообщите результат. Если ожидание не выполнено, не повторяйте шаг вслепую.

| Шаг | Ожидание | Windows 11 | Android |
|---|---|---|---|
| 1 | адрес сети `X`, не узлы | | |
| 2 | клиент запущен, адаптер/значок VPN есть, нет ошибок `vless`/`reality`/`seg` (таймауты `outbound/direct` к посторонним адресам допустимы) | | |
| 3 | `chatgpt.com`: `ip=<IP_VPS1>` | | |
| 4 | `api.ipify.org`: `X` | | |
| 5 | selected: `198.18.x.x`, AAAA нет; прямой: настоящий адрес | | (по Windows) |
| 6 | по настоящему IP без FakeIP: `ip=<IP_VPS1>` (только Windows) | | — |
| 7 | домен виден в журнале VPS2 | | |
| 8 | fail-closed: `http=000` три раза, `ip=<IP_VPS2>` ни разу, в журнале VPS2 `no route to host`; прямой трафик работает; после `sync` всё возвращается | | |
| 9 | остановка: адаптер/значок исчез, адрес снова `X` | | |

## Если что-то не прошло

Сохраните: вывод команд, строки `ERROR` из `client-tun.log` (Windows) или журнала приложения (Android), результат `sync-servers.ps1 -Mode SEG all -Check` и время проверки. Типовые причины:

- **Клиент не подключается, ошибка `reality` / `authentication`:** UUID ещё не на VPS2 (не выполнен `sync` из части 0, шаг 3) или профиль устарел (`make-client-config.ps1 -Mode SEG ИМЯ` должен показывать `current`).
- **Таймаут при подключении:** сеть блокирует 443 к VPS2 (проверьте `Test-NetConnection`) или на устройстве работает другой VPN.
- **На Windows все запросы зависли:** клиент запущен не от администратора или включён full-tunnel AmneziaWG (его kill-switch блокирует `sing-box`).
- **На Android `chatgpt.com` показывает ваш адрес, а не `<IP_VPS1>`:** включён «Частный DNS» или безопасный DNS в Chrome (вернитесь к шагу B1); либо соединение пошло по IPv6 (в этом случае запишите результат, так как проект направляет selected-трафик только по IPv4).
