# Проверка клиента SEG без full-tunnel AmneziaWG

Дополнение к пункту 42 плана. Сервер-сторона проверена через туннель; эта инструкция проверяет то, что туннель искажает: выход клиента из обычной сети, маршрутизацию selected-трафика, DNS и fail-closed. Адреса узлов в инструкции записаны как `<IP_VPS1>` (`seg-exit`) и `<IP_VPS2>` (`seg-gateway`), их значения в `servers.txt`.

## Где запускать

- **Вариант A. Другой компьютер или телефон без VPN** (предпочтительно): рабочий VPN ноутбука остаётся включённым. Нужны только профиль клиента, `sing-box` и `curl`.
- **Вариант B. Этот ноутбук:** full-tunnel клиент (`herman-wk1`) на время проверки нужно отключить, рабочий VPN пропадёт. Проверка занимает около 15 минут; после неё включите клиент снова.

Клиент SEG (TUN) и full-tunnel AmneziaWG вместе не работают (kill-switch блокирует `sing-box`).

## Подготовка

1. Профиль: `clients\generated\seg\e2e33.json` (тестовый клиент; для другого устройства можно создать свой: `add-client.ps1 -Mode SEG ИМЯ`, затем `sync-servers.ps1 -Mode SEG all`). Перед проверкой: `make-client-config.ps1 -Mode SEG e2e33` должен сообщить `current`. Передавать профиль нужно по защищённому каналу, он содержит UUID и ключи.
2. На устройстве: `sing-box.exe` и `libcronet.dll` версии 1.14.4 (проверенные копии в `tools\`) и профиль в одном каталоге.
3. Пара узлов в порядке: `sync-servers.ps1 -Mode SEG all -Check` даёт `GATEWAY=READY`, `EXIT=READY`, `BACKHAUL=UP`, `FAIL_CLOSED=OK`.
4. Вариант B: отключите full-tunnel клиент и убедитесь, что `Get-Service 'AmneziaWGTunnel*'` не показывает `Running`.

## Шаги

Команды выполняются в Windows PowerShell. Записывайте фактический результат в таблицу в конце.

1. **Базовая линия (клиент ещё не запущен).** `curl.exe -4 -s https://api.ipify.org` — запомните адрес `X`. Это адрес вашей сети, он не должен совпадать с `<IP_VPS1>` и `<IP_VPS2>`.
2. **Запуск.** От имени администратора, в каталоге с профилем: `.\sing-box.exe check -c .\e2e33.json`, затем `.\sing-box.exe run -c .\e2e33.json`. В журнале нет `ERROR`, появляется адаптер `seg-tun`.
3. **Ресурс из `seg-list` (`chatgpt.com`).** В другом окне: `curl.exe -4 -s https://chatgpt.com/cdn-cgi/trace | Select-String '^ip='`. Ожидание: `ip=<IP_VPS1>`.
4. **Ресурс вне `seg-list`.** `curl.exe -4 -s https://api.ipify.org`. Ожидание: `X` (адрес из шага 1), не `<IP_VPS1>` и не `<IP_VPS2>`.
5. **DNS.** `Resolve-DnsName chatgpt.com -Type A` — адрес из `198.18.0.0/15`; `Resolve-DnsName chatgpt.com -Type AAAA` — без ответа; `Resolve-DnsName example.com -Type A` — настоящий адрес (не `198.18.x.x`).
6. **Прямые соединения не идут через узлы.** Выполняется на ноутбуке проекта: во время шага 4 на VPS2 нет пакетов к адресу прямой цели (`ssh root@<IP_VPS2> "timeout 15 tcpdump -ni eth0 -nn host <адрес цели>"`, ожидание: 0 пакетов), а запрос по IP без SNI к selected-ресурсу (`curl.exe -4 -s --resolve chatgpt.com:443:<настоящий IP chatgpt.com> https://chatgpt.com/cdn-cgi/trace`) всё равно показывает `ip=<IP_VPS1>`.
7. **Домен доходит до VPS2.** На ноутбуке проекта: `ssh root@<IP_VPS2> "journalctl -u sing-box --since '-3min' | grep 'chatgpt.com:443'"` — есть строки `inbound connection to chatgpt.com:443` от клиента `e2e33` и `outbound connection to chatgpt.com:443` через `seg-out`.
8. **Fail-closed (только на ноутбуке проекта, клиент запущен).** Остановите backhaul на VPS2: `ssh root@<IP_VPS2> "systemctl stop awg-quick@awg-backhaul"`. Повторите шаг 3 три раза с `-m 10`: запросы не должны открываться и ни разу не должны вернуть `ip=<IP_VPS2>`. Прямой запрос (шаг 4) должен работать. Восстановление: `sync-servers.ps1 -Mode SEG all`, затем `-Check` даёт `BACKHAUL=UP`, шаг 3 снова показывает `ip=<IP_VPS1>`.
9. **Остановка.** `Ctrl+C` в окне `sing-box`. Адаптер `seg-tun` исчез (`Get-NetAdapter seg-tun` не находит), `curl.exe -4 -s https://api.ipify.org` снова даёт `X`.
10. **Возврат (вариант B).** Включите `herman-wk1` и проверьте, что `Get-Service 'AmneziaWGTunnel*'` показывает `Running`.

На ноутбуке проекта шаги 2–7 выполняют и локальные скрипты (`proto\run-tun-e2e.ps1` из окна администратора, затем `proto\tun-e2e-checks.ps1` из обычного окна; каталог `proto\` не хранится в git), результат пишется в `proto\tun-e2e-report.txt`. Ручные шаги выше дают тот же результат и подходят для другого устройства.

## Таблица результата

| Шаг | Ожидание | Факт |
|---|---|---|
| 1 | адрес сети `X`, не узлы | |
| 3 | `ip=<IP_VPS1>` | |
| 4 | `X` | |
| 5 | selected: `198.18.x.x`, AAAA нет; прямой: настоящий адрес | |
| 6 | 0 пакетов на VPS2; запрос по IP показывает `<IP_VPS1>` | |
| 7 | домен виден в журнале VPS2 | |
| 8 | запросы не открываются, `ip=<IP_VPS2>` ни разу; прямой трафик работает; после `sync` всё возвращается | |
| 9 | адаптера нет, адрес снова `X` | |

Если какой-то шаг не прошёл, не повторяйте его вслепую: сохраните вывод, `-Check` обоих узлов и журнал `sing-box` клиента и сообщите результат.
