# SEG — Selective Egress Gateway

Выборочная маршрутизация трафика через российский шлюз и зарубежный выход. Дополнительный режим проекта — управление несколькими AmneziaWG-серверами (раздел 12).

Документ — основное эксплуатационное руководство. Архитектура и требования к реализации описаны в `SEG.md` (единственная актуальная спецификация SEG), порядок разработки и результаты проверок — в `roadmap.md`, пошаговая проверка клиента из обычной сети — в `SEG-client-check.md`.

Содержание:

1. [Назначение](#1-назначение)
2. [Архитектура](#2-архитектура)
3. [Требования и запуск](#3-требования-и-запуск)
4. [Структура проекта](#4-структура-проекта)
5. [Первая настройка SEG](#5-первая-настройка-seg)
6. [Подключение устройств (Windows, Linux, Android)](#6-подключение-устройств)
7. [Ежедневные сценарии](#7-ежедневные-сценарии)
8. [Справочник конфигураций](#8-справочник-конфигураций)
9. [Справочник скриптов](#9-справочник-скриптов)
10. [Синхронизация, `-Check` и откат](#10-синхронизация-seg--check-и-откат)
11. [Диагностика, восстановление и ограничения](#11-диагностика-восстановление-и-ограничения)
12. [Дополнительный режим VPN](#12-дополнительный-режим-vpn)

## 1. Назначение

SEG (Selective Egress Gateway) решает одну задачу: часть сервисов (в первой версии списка — GitHub, GitHub Copilot, ChatGPT / OpenAI, Facebook / Messenger, Telegram, YouTube) должна открываться с зарубежного IP, а весь остальной трафик не должен терять скорость и не должен проходить через VPN.

- **Через SEG идут только ресурсы из `config/seg-list.json`** (домены, суффиксы доменов, IPv4-диапазоны). Они выходят в Интернет с IP зарубежного узла `seg-exit` (VPS1).
- **Всё остальное идёт напрямую с клиента**, с адреса его провайдера, и никаких узлов не касается.
- Клиент подключается не к зарубежному серверу, а к узлу `seg-gateway` (VPS2) в России: до него добираются по обычному маршруту, а дальше трафик уходит по закрытому каналу между узлами (backhaul AmneziaWG) за границу.

Что нужно для работы:

| Компонент | Что это | Где работает |
|---|---|---|
| Управляющий компьютер | Windows с PowerShell 5.1: хранит локальный каталог проекта (единственный источник истины) и запускает скрипты | локально |
| `seg-gateway` (VPS2) | Ubuntu 24.04 в России: принимает клиентов (VLESS + REALITY, TCP), разделяет трафик, держит fail-closed | VPS |
| `seg-exit` (VPS1) | Ubuntu 24.04 за рубежом: выход в Интернет, DNS для selected-ресурсов | VPS |
| Клиентское устройство | `sing-box` 1.14.4 с профилем: перехватывает трафик (TUN) и направляет selected-ресурсы на VPS2 | устройство пользователя |

Узлы VPS заменяемы: всё, что на них установлено, воссоздаётся из локального каталога командой `sync-servers.ps1 -Mode SEG all`.

## 2. Архитектура

```text
ресурс из seg-list:  клиент → VPS2 (seg-gateway, VLESS/REALITY) → backhaul AmneziaWG → VPS1 (seg-exit) → Интернет
остальные ресурсы:   клиент → Интернет напрямую
```

| Роль | Что делает | Ключевые файлы |
|---|---|---|
| Клиент | Перехватывает весь трафик устройства (TUN). Для доменов из `seg-list` подставляет служебные адреса FakeIP и отправляет соединение на VPS2 вместе с именем домена; остальное пропускает напрямую | профиль `sing-box` (раздел 8.5) |
| `seg-gateway` (VPS2) | Принимает клиента (REALITY), по своему серверному `seg-list` решает, куда отправить соединение, держит fail-closed и backhaul со стороны шлюза | `/etc/sing-box/config.json`, `/etc/seg/seg-failclosed.nft`, `/etc/amnezia/amneziawg/awg-backhaul.conf` |
| `seg-exit` (VPS1) | Сам устанавливает backhaul с VPS2 (VPS2 слушает порт, VPS1 подключается), выпускает трафик в Интернет (NAT), отвечает на DNS-запросы selected-доменов только через backhaul | `/etc/seg/seg-exit.nft`, `/etc/unbound/unbound.conf.d/seg.conf`, `/etc/amnezia/amneziawg/awg-backhaul.conf` |

Узлы выполняют **разные роли и имеют разные конфигурации**. Backhaul использует собственные ключи, PSK, сеть и AmneziaWG-параметры из `config/seg.env`, не связанные с режимом VPN.

### Три пути трафика

1. **Напрямую с клиента.** Ресурс вне `seg-list`: клиентский профиль (`route.final = direct`) выпускает его через обычное подключение устройства. Узлы SEG не участвуют, адрес в Интернете — адрес провайдера клиента.
2. **Selected-трафик через VPS1.** Ресурс из `seg-list`: клиент → VPS2 → backhaul → VPS1 → Интернет. Адрес в Интернете — публичный IP VPS1. DNS-запросы этих доменов тоже решает резолвер VPS1 (через backhaul), локальный резолвер VPS2 не используется.
3. **Страховочный выход через VPS2.** Если до VPS2 дошло соединение, которое серверный `seg-list` не узнал (устаревший клиентский профиль, ресурс по IP без домена и CIDR, DoH в браузере), VPS2 действует по `SEG_UNMATCHED_POLICY` из `seg.env`:
   - `direct` (по умолчанию) — выпустить соединение со своего публичного IP (метка `SEG_UNMATCHED_MARK`, не через backhaul), счётчик `UNMATCHED_DIRECT` растёт;
   - `block` — отклонить.

   При любой политике исходящий tcp/25 не через backhaul блокируется, а соединения с loopback, частными адресами, сетью backhaul и собственным публичным IP VPS2 отклоняются до проверки списка.

### Fail-closed и его границы

**Fail-closed** — правило nftables на VPS2 (таблица `inet seg_failclosed`, загружается раньше сети, `sing-box` и backhaul): пакет с меткой `SEG_MARK` не может выйти ни в один интерфейс, кроме backhaul. Метку получает только selected outbound `sing-box`. Поэтому при остановке backhaul, потере маршрута или остановке VPS1 selected-запросы **не проходят**, а не «утекают» с IP VPS2.

Границы действия:

- защищает **только selected-трафик на VPS2**: страховочный выход (путь 3) помечается другой меткой и не блокируется, это его назначение;
- не влияет на прямой трафик клиента (путь 1) и на трафик самого VPS2 (обновления, SSH);
- не защищает, если клиент вообще не использует SEG (клиент отключён или профиль не запущен): тогда ресурсы выходят с обычным адресом клиента;
- проверяется пассивно командой `-Check` (поле `FAIL_CLOSED`), а активно — остановкой backhaul вручную (сценарий в `SEG-client-check.md`).

Что видит каждый узел: VPS2 — соединения клиента и имена доменов selected-ресурсов; VPS1 — адреса назначения и DNS-запросы selected-ресурсов; прямой трафик клиента не видит никто.

## 3. Требования и запуск

### Управляющий компьютер

Все скрипты проекта запускаются на **Windows** из **Windows PowerShell 5.1**. Нужны:

- OpenSSH-клиент (`ssh`, `scp`);
- SSH-ключ для `root` на каждом VPS без парольной фразы (или загруженный в `ssh-agent`): автоматизация работает с `BatchMode=yes`;
- `sing-box` 1.14.4 в каталоге `tools\` (каталог не в git). Скачайте файлы официального релиза [v1.14.4](https://github.com/SagerNet/sing-box/releases/tag/v1.14.4): `sing-box.exe` и `libcronet.dll` из `sing-box-1.14.4-windows-amd64.zip` (ими создаётся пара REALITY и проверяются профили) и `sing-box-1.14.4-linux-amd64.tar.gz` (для VPS2). SHA-256 пакетов и файлов записаны в `seg\sing-box.sha256`; скрипты сверяют файлы перед использованием и останавливаются при несовпадении (скачайте официальный пакет заново). Исполняемый файл из `PATH` принимается только после проверки версии;
- AmneziaWG для Windows с `awg.exe` (в `PATH` или в `%ProgramFiles%\AmneziaWG`, `%ProgramFiles%\AmneziaVPN`, `%LOCALAPPDATA%\AmneziaWG`): им `generate-server-env.ps1` создаёт ключи (в режиме SEG — ключи backhaul).

### Узлы

Ubuntu 24.04, публичный IPv4, SSH-ключ для `root`. Рекомендуется 1 vCPU и 1 ГБ RAM; `seg-gateway` — в России, `seg-exit` — за рубежом. Перед первым запуском `sync` выполните вход по SSH вручную и сверьте fingerprint ключа хоста с данными провайдера (автоматизация использует `StrictHostKeyChecking=yes`).

### Клиентские устройства

Управление проектом (раздел 9) выполняется только с Windows-компьютера, а устройства, которые пользуются SEG, могут быть любыми: нужен `sing-box` 1.14.4 с поддержкой TUN. Состояние проверки:

| Платформа | Состояние |
|---|---|
| Windows 11 | подтверждено: клиент из обычной сети проверен по `SEG-client-check.md` (маршрутизация, DNS, домен на VPS2, fail-closed) |
| Linux | не проверялось на устройстве; инструкция составлена по документации `sing-box` |
| Android | не проверялось на устройстве; профиль проходит `sing-box check`, импорт и запуск в приложении не проверены |

Клиент SEG (TUN) нельзя запускать вместе с активным full-tunnel клиентом AmneziaWG: его kill-switch блокирует прямой трафик и сам `sing-box`. Hiddify в обязательные критерии первой версии не входит.

### Запуск скриптов

Скрипты определяют корень проекта по своему расположению и запускаются из любого каталога. Все пять управляющих скриптов (`sync-servers.ps1`, `add-client.ps1`, `remove-client.ps1`, `make-client-config.ps1`, `generate-server-env.ps1`) **требуют параметр `-Mode`**: `-Mode SEG` — режим SEG (`scripts\seg\*.ps1`), `-Mode VPN` — режим VPN (раздел 12). Без `-Mode` скрипт завершается ошибкой с кодом 1 до любых действий; неверное значение (не `VPN` и не `SEG`), неизвестный параметр или лишний позиционный аргумент отвергает сам PowerShell ошибкой привязки параметров (код выхода `-1`), и тоже до любых действий. Параметр именованный, порядок относительно остальных аргументов не важен, регистр значения не учитывается.

Команды в этом документе приведены полностью и пригодны для копирования:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-servers.ps1 -Mode SEG all -Check
```

Если в тексте стоит краткая форма (`sync-servers.ps1 -Mode SEG all`), она означает ту же команду с префиксом `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\`, выполняемую из корня проекта.

Без аргументов скрипты сами спрашивают недостающие параметры. Подтверждения запрашиваются через `Read-Host` в виде `[y/N]`: принимаются `y`, `yes`, `д`, `да` (согласие) и `n`, `no`, `н`, `нет` (отказ); пустой ввод означает «нет», другой ввод запрашивается повторно. Каждый ответ записывается в журнал строкой `Confirmation:`. Управляющие скрипты нельзя запускать параллельно.

## 4. Структура проекта

Локальный каталог проекта на управляющем компьютере — единственный источник истины. Секреты не должны попадать в git, облачную синхронизацию или незашифрованный резервный архив (для компьютера нужны шифрование диска и зашифрованный backup).

| Путь | Назначение | Режим | Секреты | Как создаётся | В резервную копию |
|---|---|---|---|---|---|
| `servers.txt` | список узлов (`Name;IP;Port;Role;Type;Enabled`) | оба | нет (IP узлов) | вручную из `servers.txt.example` | да |
| `servers.txt.<время>.bak` | копия перед миграцией формата (три последние) | VPN | нет | `sync-servers.ps1 -Mode VPN` | нет |
| `config/seg.env` | параметры SEG: REALITY, backhaul, метки, политика | SEG | **да** | `generate-server-env.ps1 -Mode SEG` | **да** |
| `config/seg.env.<время>.bak` | копии прежних `seg.env` (три последние, без шифрования) | SEG | **да** | при генерации и `-Restore` | нет (содержат старые ключи) |
| `config/seg.env.example` | образец формата | SEG | нет | в git | в git |
| `config/seg-list.json` | список ресурсов, идущих через VPS1 | SEG | нет | в git, правится вручную | в git |
| `clients/seg/<имя>.json` | запись SEG-клиента: имя, UUID, `enabled`, дата | SEG | **да** (UUID) | `add-client.ps1 -Mode SEG` | **да** |
| `clients/generated/seg/<имя>.json` | выдаваемый профиль `sing-box` | SEG | **да** (UUID). Публичный ключ REALITY и `short_id` передаются клиенту и сами по себе доступа не дают, но не публикуются; приватного ключа REALITY в профиле нет | `add-client.ps1`, `make-client-config.ps1` | можно не копировать |
| `clients/generated/seg/<имя>.meta.json` | метаданные профиля (версия списка, хэши) | SEG | нет | вместе с профилем | можно не копировать |
| `clients/mobile/<имя>-mobile.json` | копия профиля без `log.output` для Android (по сценарию из раздела 6.4) | SEG | **да** | вручную | нет, удалять после переноса |
| `tools\` | `sing-box.exe`, `libcronet.dll`, Linux-пакет `sing-box` | SEG | нет | скачивается вручную (раздел 3) | нет, скачивается заново |
| `seg\` | скрипты узлов (`*.sh`), шаблоны `{{VAR}}`, `sing-box.sha256` | SEG | нет | в git | в git |
| `scripts\` | управляющие скрипты, `scripts\seg\` (SEG), `scripts\lib\` (библиотеки) | оба | нет | в git | в git |
| `logs/amnezia.log` | общий журнал (ротация при 10 МБ, три архива) | оба | нет (IP и имена) | автоматически | нет |
| `config/server.env`, `config/server.env.*.bak` | серверные ключи и параметры AWG | VPN | **да** | `generate-server-env.ps1 -Mode VPN` | да (`.bak` нет) |
| `config/awg0.conf.template` | серверный шаблон и все peer | VPN | **да** | из `.example` и `add-client.ps1 -Mode VPN` | да |
| `clients/*.conf`, `clients/generated/<клиент>/*.conf` | клиентские профили AmneziaWG | VPN | **да** | `add-client.ps1`, `make-client-config.ps1` | `clients/*.conf` да, `generated` нет |
| `awg-iptables.service`, `upgrade.sh`, `bootstrap.sh`, `secure.sh` | шаблон и скрипты узлов VPN (`upgrade.sh` используется и в SEG) | оба | нет | в git | в git |
| `SEG.md`, `roadmap.md`, `SEG-client-check.md`, `CLAUDE.md` | спецификация, план, проверка клиента, инструкции для работы с проектом | — | нет | в git | в git |
| `proto\` | локальные скрипты и результаты прототипа и приёмки | — | **да** | не в git | нет |
| `OLD\` | архивы прежних версий (могут содержать старые ключи) | — | **да** | не в git | нет |

В `.gitignore` внесены `config/server.env`, `config/seg.env`, `config/awg0.conf.template`, их копии `*.bak`, `clients/`, `servers.txt`, `logs/`, `tools/`, `proto/`, `OLD/`, `*.bak`, `*.tmp`, `*.zip`.

**Права доступа на компьютере.** Файлы с секретами (`config\server.env`, `config\seg.env`, `clients\`, копии `*.bak`) наследуют права родительского каталога: если он доступен другим пользователям Windows (например, группе «Прошедшие проверку» с правом изменения), они прочитают и ключи. На общем компьютере отключите наследование и оставьте доступ только своей учётной записи, например `icacls config /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F"` (то же для `clients` и `logs`).

### Файлы на узлах SEG

| Узел | Файл | Права | Назначение |
|---|---|---|---|
| оба | `/etc/amnezia/amneziawg/awg-backhaul.conf` | 600 | backhaul (содержит ключ и PSK) |
| оба | `/etc/ssh/sshd_config.d/00-seg-hardening.conf`, `/etc/fail2ban/jail.d/sshd.local` | 644 | hardening SSH и Fail2Ban |
| `seg-gateway` | `/etc/seg/seg-failclosed.nft`, `seg-failclosed.service` | 644 | fail-closed |
| `seg-gateway` | `/etc/sing-box/config.json` (`root:sing-box`), `sing-box.service`, `/usr/local/bin/sing-box` | 640 / 644 | VLESS/REALITY и серверный `seg-list` (в конфигурации ключ REALITY и UUID клиентов) |
| `seg-exit` | `/etc/seg/seg-exit.nft`, `seg-exit-fw.service`, `seg-exit-keepalive.service`, `/etc/unbound/unbound.conf.d/seg.conf` | 644 | NAT и firewall, keepalive backhaul, DNS |
| оба | `/root/*.sh`, `/root/.seg-sync/` (временно), `/root/.seg-snapshot/` (только во время прогона) | 700 для каталогов | копии скриптов, кандидаты конфигураций, снимок для отката |
## 5. Первая настройка SEG

Путь «с нуля» для чистого проекта и двух новых VPS. Режим VPN для этого не нужен: файлы `config/server.env` и `config/awg0.conf.template` не требуются, образец `servers.txt.example` берётся только как основа.

**Что понадобится заранее:**

- два VPS с Ubuntu 24.04: будущий `seg-gateway` (в России) и `seg-exit` (за рубежом), у каждого публичный IPv4 и ваш SSH-ключ для `root`;
- Windows с PowerShell 5.1, OpenSSH-клиентом и `awg.exe` (раздел 3);
- 20–30 минут и доступ в панели провайдера (на случай переустановки образа).

### 5.1. Подготовить `sing-box` в `tools\`

Команды выполняются в Windows PowerShell из корня проекта:

```powershell
New-Item -ItemType Directory tools -Force | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-windows-amd64.zip -OutFile tools\sing-box-1.14.4-windows-amd64.zip
Invoke-WebRequest -UseBasicParsing -Uri https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-amd64.tar.gz -OutFile tools\sing-box-1.14.4-linux-amd64.tar.gz
Get-FileHash tools\sing-box-1.14.4-windows-amd64.zip, tools\sing-box-1.14.4-linux-amd64.tar.gz -Algorithm SHA256 | Format-Table Hash, Path
```

Сверьте SHA-256 с `seg\sing-box.sha256` (должно совпасть полностью):

| Файл | SHA-256 |
|---|---|
| `sing-box-1.14.4-windows-amd64.zip` | `99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df` |
| `sing-box-1.14.4-linux-amd64.tar.gz` | `699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968` |

Затем достаньте из архива `sing-box.exe` и `libcronet.dll` и проверьте их:

```powershell
Expand-Archive tools\sing-box-1.14.4-windows-amd64.zip -DestinationPath tools\unpacked -Force
Copy-Item tools\unpacked\sing-box-1.14.4-windows-amd64\sing-box.exe, tools\unpacked\sing-box-1.14.4-windows-amd64\libcronet.dll tools\
Remove-Item tools\unpacked -Recurse -Force
Get-FileHash tools\sing-box.exe, tools\libcronet.dll -Algorithm SHA256 | Format-Table Hash, Path
.\tools\sing-box.exe version
```

Ожидание: `sing-box.exe` — `8f30682ee198855440d2a7fe070d5d3653793b2d01bb8c85eea88f93bbe7c8b9`, `libcronet.dll` — `3217c6260fbca5f16072e0b79735742f40109a63bb0ff88fd6b96dd6b54a2928`, версия `1.14.4`. Архив `.zip` после этого можно удалить, `.tar.gz` оставить: он нужен для установки на `seg-gateway`.

### 5.2. Подготовить два VPS

1. Создайте VPS (Ubuntu 24.04), установите ваш SSH public key для `root`.
2. Войдите вручную и сверьте fingerprint ключа хоста с данными провайдера: `ssh root@IP_УЗЛА`. На вопрос о ключе отвечайте `yes` только после сверки. Без этого автоматизация не подключится (`StrictHostKeyChecking=yes`). Повторите для второго VPS.

### 5.3. Описать узлы в `servers.txt`

Скопируйте `servers.txt.example` в `servers.txt` и замените содержимое строками SEG (подробно о формате — раздел 8.1):

```text
Name;IP;Port;Role;Type;Enabled
seg-ru;203.0.113.20;443;seg-gateway;amnezia;true
seg-eu;198.51.100.30;;seg-exit;amnezia;true
```

- `seg-gateway`: `Port` — TCP-порт, на котором VPS2 принимает клиентов (VLESS + REALITY; обычно 443);
- `seg-exit`: `Port` пустой (у него нет публичного сервисного порта);
- `Type` у обоих — `amnezia` (тип backhaul);
- включённых узлов должно быть ровно два: один `seg-gateway` и один `seg-exit`.

### 5.4. Создать `config/seg.env`

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\generate-server-env.ps1 -Mode SEG
```

Скрипт создаст ключи REALITY и `short_id`, ключи и PSK backhaul, параметры AmneziaWG и MTU (раздел 8.2). Значения секретов на экран и в журнал не выводятся. Сразу сделайте резервную копию `config\seg.env` в зашифрованное хранилище: без него узлы придётся пересоздавать с новыми ключами, а профили клиентов выдавать заново.

### 5.5. Проверить список ресурсов

Список `config/seg-list.json` входит в git и готов к работе. Проверка:

```powershell
powershell -NoProfile -Command ". .\scripts\lib\seglist.ps1; Read-SegList .\config\seg-list.json | Format-List Version,Sha256,EnabledGroups"
```

### 5.6. Развернуть пару

Сначала проверка без изменений (до развёртывания она покажет `EXIT=NEW` и код 2: это нормально):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-servers.ps1 -Mode SEG all -Check
```

Затем развёртывание:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-servers.ps1 -Mode SEG all
```

Что делает прогон: обновляет ОС, ставит пакеты, выполняет hardening (вход только по SSH-ключу, UFW, Fail2Ban), настраивает fail-closed, backhaul, NAT и DNS на VPS1, `sing-box` на VPS2 и проверяет результат (этапы — раздел 10). Для нового узла это около 10–20 минут. Если узлу нужна перезагрузка, скрипт спросит «Reboot IP and continue the upgrade?»: ответьте `y`. Отдельного подтверждения hardening не требуется (порты открываются по ролям заранее), поэтому до запуска убедитесь, что SSH-ключ для `root` установлен.

Ожидаемый итог: `SEG pair synchronized successfully`, код выхода 0. Повторите проверку:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-servers.ps1 -Mode SEG all -Check
```

Ожидание: `GATEWAY=READY`, `EXIT=READY`, `BACKHAUL=UP`, `HANDSHAKE=FRESH`, `SELECTED_ROUTING=OK`, `BACKHAUL_DNS=OK`, `EGRESS_IP` равен публичному IP `seg-exit`, `FAIL_CLOSED=OK`, `SECURITY=OK`, код 0. Расшифровка полей — раздел 10.2. Если прогон остановился, прочитайте причину в `logs\amnezia.log` и повторите команду: она идемпотентна (раздел 10.3).

### 5.7. Создать первого клиента

Дальше — раздел 6 (подключение устройства) и сценарий «Добавить устройство» в разделе 7.

## 6. Подключение устройств

### 6.1. Перед подключением (любая платформа)

1. Профиль клиента создаётся на управляющем компьютере (сценарий «Добавить устройство», раздел 7) и перед передачей проверяется: `make-client-config.ps1 -Mode SEG ИМЯ` должен показать `current`. UUID должен быть добавлен на VPS2 (`sync-servers.ps1 -Mode SEG all` после `add-client`), иначе клиент не подключится.
2. Профиль содержит UUID клиента, публичный ключ REALITY и `short_id`. Секретен он из-за UUID (с ним можно пользоваться VPS2); публичный ключ и `short_id` без UUID доступа не дают, но не публикуются; приватного ключа REALITY в профиле нет. Передавайте профиль только по защищённому каналу (кабель, флешка), не через мессенджеры, почту и облако; после переноса удалите промежуточные копии.
3. На устройстве отключите другие VPN (AmneziaWG, Hiddify и т. п.): на Windows kill-switch full-tunnel AmneziaWG блокирует клиент SEG, на Android одновременно работает один VPN.
4. Нужен `sing-box` версии 1.14.4. Профиль строится под неё; другие версии не проверялись.

### 6.2. Windows (подтверждено)

Нужны Windows 11 x64, права администратора, Интернет без VPN, около 200 МБ.

1. Подготовьте каталог и `sing-box` (в окне PowerShell от имени администратора):

   ```powershell
   New-Item -ItemType Directory C:\seg-client -Force | Out-Null
   Set-Location C:\seg-client
   Invoke-WebRequest -UseBasicParsing -Uri https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-windows-amd64.zip -OutFile sing-box.zip
   (Get-FileHash .\sing-box.zip -Algorithm SHA256).Hash.ToLower()
   ```

   Хэш должен быть `99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df`. Иначе удалите файл и скачайте заново.

   ```powershell
   Expand-Archive .\sing-box.zip -DestinationPath .\unpacked -Force
   Copy-Item .\unpacked\sing-box-1.14.4-windows-amd64\sing-box.exe, .\unpacked\sing-box-1.14.4-windows-amd64\libcronet.dll .
   Get-ChildItem .\sing-box.exe, .\libcronet.dll | Unblock-File
   Get-FileHash .\sing-box.exe, .\libcronet.dll -Algorithm SHA256 | Format-Table Hash, Path
   .\sing-box.exe version
   ```

   Хэши: `sing-box.exe` — `8f30682ee198855440d2a7fe070d5d3653793b2d01bb8c85eea88f93bbe7c8b9`, `libcronet.dll` — `3217c6260fbca5f16072e0b79735742f40109a63bb0ff88fd6b96dd6b54a2928`. Файлы можно взять и из `tools\` управляющего компьютера. `libcronet.dll` должен лежать рядом с `sing-box.exe`.

2. Скопируйте профиль `clients\generated\seg\ИМЯ.json` в `C:\seg-client` и проверьте: `.\sing-box.exe check -c .\ИМЯ.json` (пустой вывод — профиль корректен).
3. Убедитесь, что full-tunnel AmneziaWG выключен: `Get-Service 'AmneziaWGTunnel*' | Where-Object Status -eq 'Running'` ничего не выводит.
4. Запустите клиент (окно от имени администратора, TUN-адаптеру нужны права):

   ```powershell
   .\sing-box.exe run -c .\ИМЯ.json
   ```

   Окно оставьте открытым: клиент работает, пока оно открыто. Журнал пишется в `client-tun.log` рядом с профилем. В другом окне проверьте адаптер: `Get-NetAdapter seg-tun | Select-Object Name, Status` (статус `Up`).
5. Выполните проверку после подключения (раздел 6.5).
6. Остановка: `Ctrl+C` в окне клиента; адаптер `seg-tun` исчезает вместе с процессом. Автозапуск проектом не настраивается.

Если соединение не устанавливается: UUID ещё не добавлен на VPS2 (нужен `sync`), профиль устарел по параметрам подключения (REALITY, адрес, порт: нужен новый профиль), сеть блокирует TCP-порт VPS2 (`Test-NetConnection IP_VPS2 -Port 443`), включён другой VPN.

### 6.3. Linux (не проверялось на устройстве)

Инструкция составлена по документации `sing-box` для x86_64; на реальном устройстве она не проверялась. Нужны права `root` (TUN требует `CAP_NET_ADMIN`).

1. Скачайте и проверьте пакет (для другой архитектуры возьмите соответствующий пакет со [страницы релиза](https://github.com/SagerNet/sing-box/releases/tag/v1.14.4) и сверьте SHA-256 с опубликованным там значением: в `seg\sing-box.sha256` записан только `linux-amd64`):

   ```bash
   mkdir -p ~/seg-client && cd ~/seg-client
   curl -fLO https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-amd64.tar.gz
   sha256sum sing-box-1.14.4-linux-amd64.tar.gz
   ```

   Ожидание: `699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968`.

   ```bash
   tar -xzf sing-box-1.14.4-linux-amd64.tar.gz --strip-components=1 --wildcards '*/sing-box'
   ./sing-box version
   ```

2. Скопируйте профиль `ИМЯ.json` в `~/seg-client`, проверьте `./sing-box check -c ./ИМЯ.json`.
3. Запуск и остановка:

   ```bash
   sudo ./sing-box run -c ./ИМЯ.json
   ```

   `Ctrl+C` останавливает клиент. Журнал — `client-tun.log` в текущем каталоге. Интерфейс называется `seg-tun`.
4. Проверка — раздел 6.5. Особенности DNS: профиль сам перехватывает DNS (`hijack-dns`) и для прямых доменов использует DoH `dns.google`, поэтому системные настройки DNS менять не нужно. Если `systemd-resolved` или другой локальный резолвер мешает, запишите вывод `resolvectl status` и журнал клиента: на Linux это не проверялось.

### 6.4. Android (не проверялось на устройстве)

Описание рассчитано на приложение **sing-box for Android (SFA)** — официальный клиент проекта. Профиль для него проходит `sing-box check`, но импорт и запуск на устройстве не проверялись; названия пунктов меню могут отличаться. Пошаговая версия с командами для ноутбука — в `SEG-client-check.md`, часть B.

1. **Приложение.** Инструкция рассчитана на версию 1.14.4. Варианты: APK `SFA-1.14.4-universal.apk` со [страницы релиза](https://github.com/SagerNet/sing-box/releases/tag/v1.14.4) (SHA-256 `382cd451a135b4da7dbdfb031dcc34046b2feb0cb32d3eb69655b20bd376d3f9`, проверьте на компьютере: `(Get-FileHash .\SFA-1.14.4-universal.apk -Algorithm SHA256).Hash.ToLower()`) или Google Play / F-Droid (пакет `io.nekohasekai.sfa`). Версия из магазина может отличаться от 1.14.4: такая версия в проекте не проверялась, её совместимость с профилем нужно проверять отдельно (запишите номер версии из приложения). Для Android 5 есть отдельные сборки `legacy-android-5`.
2. **Профиль для телефона.** На телефоне файл журнала по относительному пути не нужен, поэтому делается копия без `log.output`. На управляющем компьютере:

   ```powershell
   New-Item -ItemType Directory .\clients\mobile -Force | Out-Null
   $p = [IO.File]::ReadAllText((Resolve-Path .\clients\generated\seg\ИМЯ.json), [Text.Encoding]::UTF8) | ConvertFrom-Json
   $p.log.PSObject.Properties.Remove('output')
   [IO.File]::WriteAllText("$PWD\clients\mobile\ИМЯ-mobile.json", ($p | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
   .\tools\sing-box.exe check -c .\clients\mobile\ИМЯ-mobile.json
   ```

   Ожидание: `check` ничего не выводит. Копию кладите именно в `clients\mobile\`: в `clients\generated\seg\` `-Check` примет её за профиль без записи клиента и вернёт код 2.
3. **Перенос.** По кабелю скопируйте APK (если нужен) и `ИМЯ-mobile.json` в папку `Download` телефона.
4. **Установка.** Откройте APK в файловом менеджере, разрешите установку из этого источника, нажмите «Установить».
5. **Импорт.** В приложении: вкладка Profiles → «+» → тип Local → импорт из файла `ИМЯ-mobile.json`. При ошибке разбора профиль не правьте: сохраните текст ошибки.
6. **Подготовка DNS.** Отключите «Частный DNS» в настройках сети и «Безопасный DNS» в браузере: иначе DoT/DoH обходят перехват DNS, и проверка станет неоднозначной.
7. **Запуск.** Dashboard → выберите профиль → включите переключатель, подтвердите системный запрос «Подключение VPN». Вкладка Log показывает журнал.
8. Проверка — раздел 6.5. Остановка: выключить переключатель.

### 6.5. Проверка после подключения

Серверный `-Check` не подтверждает, что на устройстве стоит актуальный профиль и работает клиентская маршрутизация. Проверьте на самом устройстве при включённом клиенте.

| Что проверить | Windows (PowerShell) | Linux | Ожидание |
|---|---|---|---|
| Selected-ресурс через VPS1 | `curl.exe -4 -s https://chatgpt.com/cdn-cgi/trace \| Select-String '^ip='` | `curl -4 -s https://chatgpt.com/cdn-cgi/trace \| grep '^ip='` | `ip=` равен публичному IP `seg-exit` |
| Обычный ресурс напрямую | `curl.exe -4 -s https://api.ipify.org` | `curl -4 -s https://api.ipify.org` | адрес вашей сети (как без SEG), не IP узлов |
| DNS selected-домена, A | `Resolve-DnsName chatgpt.com -Type A` | `getent ahostsv4 chatgpt.com` | адрес входит в `198.18.0.0/15` (`198.18.x.x` или `198.19.x.x`, FakeIP) |
| DNS selected-домена, AAAA | `Resolve-DnsName chatgpt.com -Type AAAA -ErrorAction SilentlyContinue` | `dig +short AAAA chatgpt.com` (пакет `dnsutils`) | пусто: записи AAAA для selected-доменов не выдаются (`strategy ipv4_only`) |
| DNS обычного домена | `Resolve-DnsName example.com -Type A` | `getent ahostsv4 example.com` | настоящий адрес, не входящий в `198.18.0.0/15` |
| Локальная сеть | откройте страницу роутера или другое устройство вашей сети | то же | доступно как без SEG (частные адреса идут напрямую) |

На Android: откройте в браузере (лучше во вкладке «Инкогнито») `https://chatgpt.com/cdn-cgi/trace` (ожидается `ip=` публичный IP `seg-exit`) и `https://api.ipify.org` (адрес вашей сети); журнал приложения (вкладка Log) покажет `outbound/vless[seg]` для selected и `outbound/direct` для прямого. Проверки DNS на Android в приложении не выполняются, а результат Windows их на Android не подтверждает: профиль тот же, но работа DNS на Android не проверялась.

Если selected-ресурс показывает ваш адрес: профиль не запущен, устарел (раздел 6.6) или соединение пошло по IPv6 либо через DoH браузера. Если не открывается ничего из selected: смотрите `-Check` (раздел 10.2) и журнал клиента.

### 6.6. Обновление профиля на устройстве

Профиль нужно пересоздавать и менять на устройстве, когда `-Check` или `make-client-config.ps1 -Mode SEG` показывает `STALE` (раздел 8.4): после изменения `seg-list.json`, смены адреса или порта VPS2, ротации ключей REALITY.

1. На управляющем компьютере: `make-client-config.ps1 -Mode SEG ИМЯ` (подтвердите «Create the profile?»). Для Android заново сделайте копию в `clients\mobile\` (раздел 6.4, шаг 2).
2. Остановите клиент на устройстве, замените файл профиля (Android: удалите старый профиль в приложении и импортируйте новый), запустите клиент.
3. Повторите проверку раздела 6.5.

Профиль, устаревший **по списку**, продолжает подключаться, но новые ресурсы из списка клиент отправляет напрямую, а не на VPS2: пока профиль не заменён, они выходят с адреса провайдера. Профиль, устаревший **по параметрам подключения**, подключиться уже не сможет.

### 6.7. Удаление клиента с устройства

1. Остановите клиент. Windows и Linux: удалите каталог с `sing-box` и профилем (`C:\seg-client`, `~/seg-client`). Android: удалите профиль в приложении и при необходимости само приложение; удалите `ИМЯ-mobile.json` и APK из `Download`.
2. **Отзовите доступ на сервере**: удаление файлов на устройстве доступ не отзывает, пока UUID действует на VPS2. Сценарий «Удалить устройство и отозвать UUID» — раздел 7.
## 7. Ежедневные сценарии

Каждый сценарий: исходные условия → действия на управляющем компьютере → действия на устройстве → ожидаемый результат. Команды приведены в краткой форме (префикс `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\`, раздел 3). `ИМЯ` — имя клиента (латиница, цифры, `.`, `_`, `-`; раздел 8.4).

### 7.1. Подготовка проекта и первая настройка пары

Выполняется один раз, подробно — раздел 5: `tools\` с `sing-box`, `servers.txt` с двумя узлами, `generate-server-env.ps1 -Mode SEG`, `sync-servers.ps1 -Mode SEG all`. Результат — `-Check` пары `OK`, код 0.

### 7.2. Добавить устройство

- **Условия:** пара узлов развёрнута (`-Check` без ошибок), на устройстве есть `sing-box` 1.14.4 (раздел 6).
- **На управляющем компьютере:**
  1. `add-client.ps1 -Mode SEG ИМЯ` — создаёт запись клиента (случайный UUID) и профиль; на вопрос «Create client?» ответьте `y`.
  2. `sync-servers.ps1 -Mode SEG all` — добавляет UUID в пользователей `sing-box` на VPS2 (служба перезапускается, подключения других клиентов на секунды прервутся).
  3. `make-client-config.ps1 -Mode SEG ИМЯ` — должно быть «is current»; на вопрос «Recreate it anyway?» ответьте `n`.
  4. Передайте `clients\generated\seg\ИМЯ.json` на устройство по защищённому каналу (для Android — копию из `clients\mobile\`, раздел 6.4).
- **На устройстве:** установка и запуск — раздел 6.2 (Windows), 6.3 (Linux) или 6.4 (Android).
- **Ожидание:** проверки раздела 6.5 проходят (selected — IP `seg-exit`, обычный ресурс — адрес вашей сети).

### 7.3. Обновить профиль

- **Условия:** `-Check` или `make-client-config.ps1 -Mode SEG` показывает для клиента `STALE` (раздел 8.4).
- **На управляющем компьютере:** если причина — изменение серверных параметров, сначала примените их: `sync-servers.ps1 -Mode SEG all`; затем `make-client-config.ps1 -Mode SEG ИМЯ` (подтвердить «Create the profile?»).
- **На устройстве:** остановить клиент, заменить профиль, запустить (раздел 6.6).
- **Ожидание:** `make-client-config.ps1 -Mode SEG ИМЯ` показывает `current`, проверки 6.5 проходят.

### 7.4. Временно отключить и снова включить устройство

Скрипта для этого нет: поле `enabled` правится вручную в записи клиента.

- **Отключить:**
  1. На управляющем компьютере откройте в текстовом редакторе `clients\seg\ИМЯ.json` и замените `"enabled": true` на `"enabled": false` (остальные поля не трогайте, файл остаётся в UTF-8, имя файла должно совпадать с полем `name`).
  2. `sync-servers.ps1 -Mode SEG all`: UUID исчезает из конфигурации VPS2, `sing-box` перезапускается, активные соединения клиента завершаются.
  3. `-Check` покажет клиента как `DISABLED`; `make-client-config.ps1 -Mode SEG ИМЯ` для отключённого клиента завершится ошибкой.
- **Включить:** верните `"enabled": true`, выполните `sync-servers.ps1 -Mode SEG all`. Прежний профиль остаётся действующим (UUID тот же), если не `STALE`; проверьте `make-client-config.ps1 -Mode SEG ИМЯ` (ответ `n` на пересоздание).
- **На устройстве:** при отключении клиент перестанет подключаться (сервер не принимает UUID); при включении запустите его снова.
- **Ожидание:** до `sync` отключение не действует, UUID остаётся рабочим.

### 7.5. Удалить устройство и отозвать UUID

- **Условия:** устройство больше не нужно или потерян профиль.
- **На управляющем компьютере:**
  1. `remove-client.ps1 -Mode SEG ИМЯ` (подтвердить «Remove client?»): удаляет запись, профиль и метаданные.
  2. `sync-servers.ps1 -Mode SEG all` — **без этого UUID продолжает действовать**; недоступный VPS2 прервёт `sync`, и отзыв не состоится. При утечке профиля выполните `sync` немедленно.
  3. Если был сделан файл для Android, удалите `clients\mobile\ИМЯ-mobile.json`.
- **На устройстве:** удалите клиент и профиль (раздел 6.7).
- **Ожидание:** клиент не подключается; в `-Check` его нет в списке клиентов. Ротация UUID без смены имени: `remove-client.ps1 -Mode SEG ИМЯ` → `add-client.ps1 -Mode SEG ИМЯ` → `sync-servers.ps1 -Mode SEG all` → новый профиль на устройство.

### 7.6. Изменить список ресурсов

- **Условия:** нужно добавить или убрать домены, суффиксы, диапазоны (формат — раздел 8.3).
- **На управляющем компьютере:**
  1. Отредактируйте `config\seg-list.json` и **повысьте `version`**.
  2. Проверка: `powershell -NoProfile -Command ". .\scripts\lib\seglist.ps1; Read-SegList .\config\seg-list.json | Format-List Version,Sha256,EnabledGroups"`.
  3. `sync-servers.ps1 -Mode SEG -Check all`: `GATEWAY=CHANGES`, у клиентов `STALE` (код 2).
  4. `sync-servers.ps1 -Mode SEG all`: серверный `sing-box` получает новые правила и перезапускается.
  5. Для **каждого** клиента `make-client-config.ps1 -Mode SEG ИМЯ`.
- **На устройствах:** заменить профили (раздел 6.6).
- **Ожидание:** `-Check` пары `OK`, профили `CURRENT`; новый ресурс выходит с IP `seg-exit`. Пока профиль не заменён, новый ресурс идёт с устройства напрямую.

### 7.7. Изменить политику страховочного выхода

- Правка `SEG_UNMATCHED_POLICY` (`direct` или `block`) в `config\seg.env`, затем `sync-servers.ps1 -Mode SEG all` (`sing-box` перезапускается). Новые профили не нужны: политика не входит в параметры подключения клиента.
- **Ожидание:** при `block` ресурс вне серверного списка, дошедший до VPS2, не открывается; `UNMATCHED_DIRECT` в `-Check` перестаёт расти.

### 7.8. Заменить или перенести узел

Порядок для `seg-exit`, `seg-gateway`, переустановки образа и смены IP — раздел 11.2. Кратко для `seg-exit`: создать новый VPS и сверить его host key, **остановить старый узел до `sync`** (`ssh root@СТАРЫЙ_IP "systemctl disable --now seg-exit-keepalive awg-quick@awg-backhaul"` или уничтожить его), заменить IP в `servers.txt`, выполнить `sync-servers.ps1 -Mode SEG all` и `-Check` (`EGRESS_IP` нового узла, код 0), после этого `ssh-keygen -R СТАРЫЙ_IP`; профили клиентов остаются прежними. Для `seg-gateway` порядок другой (раздел 11.2): клиентам нужны новые профили (раздел 7.3), `-Check` даёт код 0 только после их пересоздания. Смена только порта шлюза — отдельный сценарий без нового VPS и без остановки узла (раздел 11.2).

### 7.9. Ротация ключей, компрометация, восстановление на другом компьютере

Раздел 11.3 (ротация и компрометация VPS1, VPS2, ноутбука) и раздел 11.4 (восстановление на другом компьютере).
## 8. Справочник конфигураций

### 8.1. `servers.txt`

Список узлов; формат строк `Name;IP;Port;Role;Type;Enabled` (разделитель `;`, первая строка — заголовок). Пример для режима SEG:

```text
Name;IP;Port;Role;Type;Enabled
seg-ru;203.0.113.20;443;seg-gateway;amnezia;true
seg-eu;198.51.100.30;;seg-exit;amnezia;true
```

Пример файла, в котором режимы сосуществуют (разные хосты):

```text
Name;IP;Port;Role;Type;Enabled
vpn-01;203.0.113.10;42157;vpn-server;amnezia;true
seg-ru;203.0.113.20;443;seg-gateway;amnezia;true
seg-eu;198.51.100.30;;seg-exit;amnezia;true
```

| Поле | Смысл |
|---|---|
| `Name` | уникальное имя узла (латиница, цифры и т. п.; повтор запрещён) |
| `IP` | публичный IPv4 узла |
| `Port` | `seg-gateway` — **TCP**-порт VLESS/REALITY (1–65535); `vpn-server` — **UDP**-порт AmneziaWG; `seg-exit` — **пустой** (публичного сервисного порта нет; непустое значение — ошибка) |
| `Role` | `seg-gateway`, `seg-exit` или `vpn-server`; роль определяет, каким режимом управляется хост |
| `Type` | `amnezia` у всех ролей (сейчас реализован только он). `seg-gateway` допускает список через запятую (типы backhaul на шлюзе), `seg-exit` и `vpn-server` — одно значение; `seg-exit.Type` должен входить в список `seg-gateway.Type`. `sing-box` в `Type` не пишется: он подразумевается ролью `seg-gateway` |
| `Enabled` | `true` или `false`; отключённый узел исключается из `sync` |

Правила выбора пары в режиме SEG: ровно один включённый `seg-gateway` и один включённый `seg-exit` (иначе «SEG mode requires exactly one enabled seg-gateway and one enabled seg-exit»). Строки `vpn-server` режим SEG не затрагивает, а режим VPN не затрагивает `seg-*`. Уникальна пара `IP:Port` среди строк с заданным `Port`.

**Один хост — один режим.** Валидатор не запрещает указать один IP в строках разных режимов (у `seg-exit` порт пуст и в проверку уникальности не входит), но это приводит к тому, что `-Mode VPN` и `-Mode SEG` настраивают одну машину по-разному. Для неиспользуемого режима поставьте `Enabled=false`.

Скрипты проверяют файл при каждом запуске и останавливаются с понятным сообщением при ошибке (неизвестная роль, неподдерживаемый `Type`, неверный порт, повтор `Name` или `IP:Port`).

**Миграция старого формата** (`Name;IP;Port;Enabled`, только режим VPN). Прежний формат мигрируется автоматически (все строки получают `Role=vpn-server`, `Type=amnezia`), но только обычным запуском `sync-servers.ps1 -Mode VPN` (не `-Check`). Перед заменой создаётся копия `servers.txt.<время>.bak` (три последние), новый файл проверяется и только потом заменяет исходный; при ошибке проверки исходный файл не меняется. `add-client.ps1`, `make-client-config.ps1` и `sync-servers.ps1 -Mode SEG` при старом формате останавливаются и просят сначала выполнить `sync-servers.ps1 -Mode VPN`. Режим `-Check` файл не изменяет: он читает старый формат как `vpn-server` + `amnezia` и пишет «migration is required».

### 8.2. `config/seg.env`

Образец формата — `config/seg.env.example`; рабочий файл создаёт `generate-server-env.ps1 -Mode SEG` (раздел 9.2). Формат `NAME=VALUE`, комментарии `#`; неизвестные и повторяющиеся параметры отвергаются. Параметры с суффиксом `_VPS1` относятся к `seg-exit`, с `_VPS2` — к `seg-gateway`. Порт VLESS здесь не хранится: это `Port` у `seg-gateway` в `servers.txt`; UUID клиентов лежат в `clients/seg/`.

| Группа | Параметры | Секрет | Кто задаёт |
|---|---|---|---|
| REALITY: приватный ключ | `SEG_REALITY_PRIVATE_KEY` | **да** (только узел `seg-gateway` и `seg.env`) | генератор, заново при каждой генерации |
| REALITY: публичный ключ и `short_id` | `SEG_REALITY_PUBLIC_KEY`, `SEG_REALITY_SHORT_ID` | нет в смысле доступа: передаются клиентам в профиле, без UUID по ним подключиться нельзя; не публикуйте их (хранятся в `seg.env` вместе с секретами) | генератор, заново при каждой генерации |
| REALITY | `SEG_REALITY_SERVER_NAME`, `SEG_REALITY_DEST` (`host:port`), `SEG_REALITY_FLOW`, `SEG_REALITY_FINGERPRINT` | нет | по умолчанию `www.microsoft.com`; сохраняются при перегенерации, можно править |
| Backhaul: ключи | `SEG_BACKHAUL_PRIVATE_KEY_VPS1/VPS2`, `SEG_BACKHAUL_PUBLIC_KEY_VPS1/VPS2`, `SEG_BACKHAUL_PSK` | да (приватные ключи, PSK) | генератор |
| Backhaul: сеть | `SEG_BACKHAUL_NETWORK` (/30), `SEG_BACKHAUL_VPS1`, `SEG_BACKHAUL_VPS2`, `SEG_BACKHAUL_PORT` (UDP), `SEG_BACKHAUL_INTERFACE` (не `awg0`) | нет | по умолчанию `10.77.0.0/30` (VPS1 — `10.77.0.2`, VPS2 — `10.77.0.1`), порт 42100, `awg-backhaul`; сохраняются |
| Backhaul: AmneziaWG | `SEG_BACKHAUL_JC`, `_JMIN`, `_JMAX`, `_S1`–`_S4`, `_H1`–`_H4`, `SEG_BACKHAUL_RANDOM_TRAILERS` | нет (но не публикуйте) | генератор (кроме `RANDOM_TRAILERS`, он сохраняется) |
| Backhaul: MTU | `SEG_BACKHAUL_MTU` | нет | только генератор: предел без фрагментации по `S4` и `RandomTrailers` минус 16 байт (при `S4 = 144` и `on` это 800); вручную не задаётся |
| Метки nftables | `SEG_MARK` (selected-трафик, fail-closed), `SEG_UNMATCHED_MARK` (страховочный DIRECT, счётчик `UNMATCHED_DIRECT`) | нет | по умолчанию `0x5e90` и `0x5e91`: hex не меньше `0x1000`, различны, не равны `0xca6c` |
| Политика | `SEG_UNMATCHED_POLICY` (`direct` или `block`) | нет | можно править (раздел 2, «Три пути трафика») |

Валидатор (`scripts\lib\segenv.ps1`) проверяет все параметры и сообщает о всех проблемах сразу, не выводя значения секретов: форматы и длины ключей, различие ключей между собой, `short_id` (2–16 hex, чётное число), сеть backhaul (/30, без пересечения с зарезервированными, в том числе с сетью клиентов VPN), адреса внутри сети, диапазоны AmneziaWG (`Jmin ≤ Jmax`, `S1–S4` 15–150, `H1–H4` уникальны), `MTU` не выше предела без фрагментации. Ручная правка допустима только для нечувствительных параметров из таблицы; после неё нужны `sync-servers.ps1 -Mode SEG all` и, если изменились параметры подключения клиента (адрес, REALITY), новые профили клиентов. Резервные копии — раздел 9.2 (`generate-server-env.ps1`).

### 8.3. `config/seg-list.json`

`config/seg-list.json` — единственный источник правил «какие ресурсы идут через VPS1». Файл не содержит секретов и хранится в git.

```json
{
  "version": 1,
  "groups": [
    { "name": "github", "title": "GitHub", "enabled": true,
      "domains": [], "domain_suffixes": ["github.com"], "cidrs": [],
      "sources": ["https://api.github.com/meta, checked 2026-11-09"] }
  ]
}
```

- `domains` — точное имя, `domain_suffixes` — имя и все его поддомены, `cidrs` — IPv4-диапазоны (для ресурсов, к которым обращаются по IP, например Telegram), `sources` — откуда взят список. `enabled: false` выключает группу целиком.
- В первой версии группы: GitHub, GitHub Copilot, ChatGPT / OpenAI, Facebook / Messenger, Telegram, YouTube. Сервис обычно использует много доменов (для видео YouTube нужны `googlevideo.com`, `ytimg.com`, `ggpht.com` и `jnn-pa.googleapis.com`), поэтому домен вне списка идёт напрямую и может быть недоступен из РФ.
- Проверка: `powershell -NoProfile -Command ". .\scripts\lib\seglist.ps1; Read-SegList .\config\seg-list.json | Format-List Version,Sha256,EnabledGroups"`. Валидатор сообщает обо всех ошибках сразу: недопустимые имена, IPv6, частные диапазоны, пересечение с FakeIP, дубли, пустые включённые группы, неизвестные поля.
- **Порядок изменения списка:** отредактировать файл, повысить `version`, проверить командой выше, применить на серверах (`sync-servers.ps1 -Mode SEG all`: серверный `sing-box` получает новые правила и перезапускается), затем пересоздать профили клиентов (`make-client-config.ps1 -Mode SEG`) и раздать их устройствам. Профиль привязан к SHA-256 списка и после изменения считается устаревшим; `sync-servers.ps1 -Mode SEG -Check all` перечисляет такие профили (код выхода `2`). Если содержимое изменено, а `version` нет, сообщение об этом напомнит повысить версию (определяет устаревание хэш, версия нужна людям). Серверный список применяется независимо от версии профиля: ресурс из нового списка, соединение с которым дошло до VPS2, выходит через VPS1, а остальное обработает политика `SEG_UNMATCHED_POLICY` (раздел 2). Но устаревший клиент такой ресурс на VPS2 вообще не отправляет: он идёт напрямую (с адресом провайдера клиента) до пересоздания профиля, поэтому профили нужно пересоздавать и раздавать после каждого изменения списка.
- SHA-256 считается по содержимому с приведением переводов строк к LF и без BOM, поэтому не зависит от того, как git выгрузил файл.

### 8.4. Клиенты SEG: три разных JSON-файла

У каждого клиента три файла с разными ролями. Не путайте их:

| Файл | Что это | Кто создаёт | Править вручную |
|---|---|---|---|
| `clients/seg/<имя>.json` | **запись клиента** (реестр): кто он и включён ли | `add-client.ps1 -Mode SEG` | только поле `enabled` (раздел 7.4) |
| `clients/generated/seg/<имя>.json` | **выдаваемый профиль** `sing-box`, который устанавливается на устройство | `add-client.ps1`, `make-client-config.ps1` | нет: пересоздаётся скриптом |
| `clients/generated/seg/<имя>.meta.json` | **метаданные** профиля: по ним определяется его актуальность | вместе с профилем | нет |

#### Запись клиента `clients/seg/<имя>.json`

```json
{
  "name": "laptop-anna",
  "uuid": "0b2f4c1e-7d3a-4f5b-9c1d-2e8a6b7c9d10",
  "enabled": true,
  "created": "2026-11-09T14:30:00.0000000+03:00"
}
```

| Поле | Тип и формат | Обязательно | Ограничения | Влияние изменения |
|---|---|---|---|---|
| `name` | строка, 1–64 символа: латиница, цифры, `.`, `_`, `-`; первый символ буква или цифра, точки в конце нет | да | совпадает с именем файла (без учёта регистра); не оканчивается на `.meta`; не зарезервированное имя устройства Windows (`con`, `nul`, `com1` …); имена уникальны без учёта регистра. Служит именем пользователя на VPS2 | менять нельзя: переименование = удаление и новый клиент |
| `uuid` | строка: UUID строчными буквами `8-4-4-4-12` | да | не нулевой UUID; у каждого клиента свой | менять нельзя: профиль на устройстве хранит прежний UUID и перестанет подключаться. Для замены — `remove-client.ps1` и `add-client.ps1` (раздел 7.5) |
| `enabled` | `true` или `false` (булево, не строка) | да | — | `false` — UUID не попадает в конфигурацию VPS2 при следующем `sync`, `make-client-config.ps1` для такого клиента не работает (раздел 7.4) |
| `created` | строка: дата и время ISO 8601 с часовым поясом (`2026-11-09T14:30:00.0000000+03:00`) | да | формат `o` .NET | справочное поле, ни на что не влияет |

Файл — UTF-8 без BOM, переводы строк LF. Любое **неизвестное** или **отсутствующее** поле, неверный тип или формат делает файл недопустимым: скрипты (`sync`, `add-client`, `make-client-config`) останавливаются с сообщением «… is invalid» и перечислением проблем, ничего не меняя. То же при двух клиентах с одним UUID или с именами, различающимися только регистром. UUID — единственный секрет клиента: тот, кто его знает, может пользоваться VPS2. UUID в сообщения и журнал не выводится.

#### Метаданные профиля `clients/generated/seg/<имя>.meta.json`

```json
{
  "segListVersion": 1,
  "segListSha256": "<64 hex>",
  "serverConfigSha256": "<64 hex>",
  "generatedAt": "2026-11-10T23:24:07.8024591+03:00"
}
```

| Поле | Формат | Что означает |
|---|---|---|
| `segListVersion` | целое число ≥ 1 | `version` из `seg-list.json` на момент сборки профиля (для людей) |
| `segListSha256` | 64 hex-символа строчными | SHA-256 `seg-list.json` на момент сборки (по ним определяется устаревание по списку) |
| `serverConfigSha256` | 64 hex-символа строчными | SHA-256 параметров подключения: адрес и порт VPS2, `SEG_REALITY_SERVER_NAME`, `SEG_REALITY_PUBLIC_KEY`, `SEG_REALITY_SHORT_ID`, `SEG_REALITY_FLOW`, `SEG_REALITY_FINGERPRINT` (устаревание по параметрам подключения) |
| `generatedAt` | ISO 8601 с часовым поясом | время сборки |

Все четыре поля обязательны, лишние и неверные отвергаются (`BROKEN`).

#### Состояние профиля

Актуальность определяет `Get-SegProfileStatus` (`scripts\lib\segclients.ps1`) по метаданным; `sync-servers.ps1 -Mode SEG` (в том числе с `-Check`) и `make-client-config.ps1 -Mode SEG` выводят его для каждого клиента:

| Состояние | Когда | Что делать |
|---|---|---|
| `CURRENT` | профиль собран по текущему `seg-list.json` и текущим параметрам подключения | ничего |
| `STALE` по списку | изменился `seg-list.json` (по хэшу). Профиль **подключается**, но ресурсы, добавленные в список после его выдачи, клиент отправляет напрямую, а не на VPS2: они выходят с адреса провайдера клиента. Если изменилось содержимое, а `version` нет, сообщение напомнит её повысить | пересоздать и заменить профиль (раздел 7.3) |
| `STALE` по параметрам подключения | изменились адрес или порт VPS2, ключи REALITY, `short_id`, `flow`, `fingerprint`: профиль **подключиться уже не сможет** | пересоздать и заменить профиль (раздел 7.3) |
| `MISSING` | профиль ещё не создан | `make-client-config.ps1 -Mode SEG ИМЯ` |
| `BROKEN` | нет профиля или метаданных либо метаданные нечитаемы | пересоздать профиль |
| `DISABLED` | клиент отключён (`enabled: false`) | включить (раздел 7.4) |

Файлы профилей без записи клиента считаются «осиротевшими» (`WARN`, `-Check` возвращает код 2): удалите их или пересоздайте клиента. Добавление и удаление других клиентов и изменение параметров, не влияющих на подключение (backhaul, политика), профиль не устаревают. Имя `seg` в режиме VPN зарезервировано: `add-client.ps1 -Mode VPN seg` завершается ошибкой, потому что каталог `clients/generated/seg` принадлежит режиму SEG; файлы SEG имеют расширение `.json`, а `sync-servers.ps1 -Mode VPN` затрагивает только `*.conf`.

### 8.5. Выдаваемый профиль `sing-box`

Профиль — полный конфиг `sing-box` 1.14.4, собранный из шаблона `seg/templates/sing-box-client-tun.json.template`. Значения берутся из `seg.env`, `servers.txt`, `seg-list.json` и записи клиента. Ниже — все поля фактического профиля. Работа на Windows подтверждена; платформенные замечания — в последней колонке.

| JSON-путь | Значение | Источник | Назначение | Платформы и замечания |
|---|---|---|---|---|
| `log.level` | `info` | шаблон | уровень журнала (`trace`, `debug`, `info`, `warn`, `error`) | можно менять (например, на `warn`) |
| `log.output` | `client-tun.log` | шаблон | файл журнала; относительный путь — рядом с текущим каталогом | **на Android удаляется** (копия для телефона, раздел 6.4) |
| `log.timestamp` | `true` | шаблон | время в строках журнала | — |
| `dns.servers[0].type` | `https` | шаблон | прямой DNS по протоколу DNS-over-HTTPS | порт 53 при `strict_route` на Windows блокируется (в том числе для самого `sing-box`), поэтому прямой DNS только DoH |
| `dns.servers[0].tag` | `dns-direct` | шаблон | имя сервера: на него ссылаются `dns.final` и `route.default_domain_resolver` | — |
| `dns.servers[0].server` | `8.8.8.8` | шаблон | адрес DoH-сервера | — |
| `dns.servers[0].tls.server_name` | `dns.google` | шаблон | имя для TLS: SNI и проверка сертификата DoH-сервера | — |
| `dns.servers[1].type` | `fakeip` | шаблон | «сервер», выдающий служебные адреса вместо настоящих: так клиент узнаёт имя домена при перехвате соединения | — |
| `dns.servers[1].tag` | `dns-fakeip` | шаблон | имя сервера для `dns.rules[0]` | — |
| `dns.servers[1].inet4_range` | `198.18.0.0/15` | шаблон | диапазон служебных адресов FakeIP (IPv4) | адреса из него не должны встречаться в `seg-list` |
| `dns.rules[0].rule_set` | `[seg-domains]` | `seg-list.json` | к каким доменам применяется правило | меняется при изменении списка |
| `dns.rules[0].action`, `dns.rules[0].server` | `route`, `dns-fakeip` | шаблон | домены из списка получают FakeIP; настоящий запрос выполняет VPS2 через VPS1 | — |
| `dns.final` | `dns-direct` | шаблон | сервер для всех остальных доменов (настоящие адреса) | — |
| `dns.strategy` | `ipv4_only` | шаблон | стратегия по умолчанию для всех доменных запросов в этой DNS-настройке: только записи A | **Проверено:** для selected-доменов AAAA не возвращается. Так как поле глобальное, того же ожидают и для обычных доменов (клиент не узнаёт их IPv6-адреса через DNS), но это на устройстве не проверялось. Соединения по готовому IPv6-адресу (без DNS) от этого поля не зависят: у адаптера только IPv4-адрес, поведение IPv6 зависит от платформы и `strict_route`, на тестовом канале IPv6 не было (раздел 11.6) |
| `inbounds[0].type` | `tun` | шаблон | перехват трафика всего устройства через виртуальный сетевой адаптер | Windows и Linux: нужны права администратора/root. Android: TUN создаёт приложение, не проверялось |
| `inbounds[0].tag` | `tun-in` | шаблон | имя входа | — |
| `inbounds[0].interface_name` | `seg-tun` | шаблон | имя адаптера | исчезает вместе с процессом |
| `inbounds[0].address` | `["172.19.0.1/30"]` | шаблон | внутренний адрес адаптера | не должен пересекаться с вашими сетями |
| `inbounds[0].auto_route` | `true` | шаблон | `sing-box` сам настраивает маршруты ОС, направляя весь трафик в TUN | при аварийном завершении маршруты снимаются вместе с адаптером |
| `inbounds[0].strict_route` | `true` | шаблон | по документации `sing-box`: делает недоступными сети, которые TUN не поддерживает; на Windows дополнительно блокирует DNS (порт 53) в обход TUN и закрывает утечки DNS при нескольких интерфейсах | Это **не гарантия перехвата всего трафика** (приложения со своими адаптерами и туннелями, другие VPN) и **не клиентский fail-closed**: при остановке или падении `sing-box` адаптер и маршруты исчезают, устройство работает напрямую, и selected-ресурсы выходят с обычного адреса клиента. Именно из-за блокировки порта 53 на Windows прямой DNS в профиле — DoH |
| `inbounds[0].stack` | `mixed` | шаблон | сетевой стек TUN: смешанный (TCP — системный стек, UDP — gVisor) | — |
| `outbounds[0].type` | `vless` | шаблон | выход на VPS2 по протоколу VLESS | — |
| `outbounds[0].tag` | `seg` | шаблон | имя выхода: на него ссылается `route.rules[4]` | — |
| `outbounds[0].server` | IP `seg-gateway` | `servers.txt` | адрес VPS2 | при смене IP VPS2 профиль `STALE` по параметрам подключения |
| `outbounds[0].server_port` | TCP-порт `seg-gateway` | `servers.txt` (`Port`) | порт VPS2 | то же |
| `outbounds[0].uuid` | UUID клиента | `clients/seg/<имя>.json` | идентификатор клиента: по нему VPS2 решает, пускать ли | **секрет** |
| `outbounds[0].flow` | `xtls-rprx-vision` | `SEG_REALITY_FLOW` | режим VLESS Vision (скрывает характерные признаки TLS внутри TLS); должен совпадать с сервером | — |
| `outbounds[0].packet_encoding` | `xudp` | шаблон | способ передачи UDP внутри VLESS (XUDP) | UDP через VLESS на прототипе не проверялся |
| `outbounds[0].tls.enabled` | `true` | шаблон | включает TLS (в составе REALITY) | — |
| `outbounds[0].tls.server_name` | `www.microsoft.com` по умолчанию | `SEG_REALITY_SERVER_NAME` | имя сайта-прикрытия: его видит сторонний наблюдатель в SNI | должно совпадать с настройкой сервера |
| `outbounds[0].tls.utls.enabled`, `.fingerprint` | `true`, `chrome` | `SEG_REALITY_FINGERPRINT` | имитация отпечатка TLS-приветствия браузера `chrome` | — |
| `outbounds[0].tls.reality.enabled` | `true` | шаблон | включает REALITY | — |
| `outbounds[0].tls.reality.public_key` | публичный ключ REALITY | `SEG_REALITY_PUBLIC_KEY` | клиент убеждается, что отвечает именно ваш VPS2 | не секрет; после ротации ключей профиль нужно заменить |
| `outbounds[0].tls.reality.short_id` | `short_id` | `SEG_REALITY_SHORT_ID` | идентификатор клиента REALITY: сервер принимает только известные значения | не раскрывает приватный ключ; после ротации профиль нужно заменить |
| `outbounds[1].type`, `.tag` | `direct`, `direct` | шаблон | прямой выход через обычное подключение устройства | — |
| `route.rules[0]` | `action: sniff` | шаблон | определяет протокол и домен соединения (TLS SNI, QUIC) | — |
| `route.rules[1]` | `protocol: dns` → `action: hijack-dns` | шаблон | перехват DNS-запросов клиента и передача их в `dns` | — |
| `route.rules[2]` | `ip_is_private: true` → `outbound: direct` | шаблон | локальная сеть идёт напрямую | — |
| `route.rules[3]` | домены из списка, `network: udp`, `port: 443` → `action: reject` | `seg-list.json` | отклонение QUIC к selected-ресурсам: браузер переходит на TCP | — |
| `route.rules[4]` | `rule_set: [seg-domains, seg-cidrs]` → `outbound: seg` | `seg-list.json` | selected-ресурсы уходят на VPS2 | `seg-cidrs` присутствует только если в списке есть диапазоны |
| `route.rule_set[].type` | `inline` | шаблон | набор правил хранится внутри профиля, а не скачивается | — |
| `route.rule_set[].tag` | `seg-domains`, `seg-cidrs` | шаблон | имена наборов для `dns.rules` и `route.rules` | — |
| `route.rule_set[].rules[]` | `domain`, `domain_suffix` (для `seg-domains`), `ip_cidr` (для `seg-cidrs`) | `seg-list.json` | точные домены, домены с поддоменами, IPv4-диапазоны | меняются при изменении списка |
| `route.final` | `direct` | шаблон | всё остальное — напрямую | — |
| `route.auto_detect_interface` | `true` | шаблон | исходящие соединения (к VPS2 и прямые) привязываются к физическому интерфейсу, чтобы не попасть в собственный TUN | — |
| `route.default_domain_resolver` | `dns-direct` | шаблон | какой DNS использовать для имён, встречающихся в самих настройках | — |

Перед выдачей профиль проверяется (`scripts\lib\segprofile.ps1`): подстановка без нерешённых переменных и корректный JSON; структурная сверка с правилами выше (в том числе что обычный DNS на порту 53 не используется, а значения профиля совпадают с `seg.env`, `servers.txt` и клиентом); адреса VPS1 и VPS2 не входят в диапазоны `seg-list` (иначе управляющий трафик, например SSH, ушёл бы в собственный туннель клиента); `sing-box check` локальным проверенным `tools\sing-box.exe`. Работа профиля на ноутбуке (TUN, DNS, QUIC) проверена на клиенте Windows.

**Ручные изменения.** Профиль пересоздаётся скриптом и перезаписывается целиком, поэтому правки теряются при следующем `make-client-config.ps1`. Допустимо менять только `log.level` и путь `log.output`. Изменение полей подключения (`server`, `server_port`, `uuid`, `tls`, `flow`) сломает соединение, а правки правил маршрутизации и DNS выведут клиента из проверенного состояния.

**Переносимость.** Подтверждена работа профиля на Windows 11. Linux: запуск не проверялся. Android: подготовленная копия без `log.output` проходит `sing-box check` Windows-бинарником `tools\sing-box.exe`; импорт и запуск в SFA на устройстве, а также работа DNS и маршрутизации на Android не подтверждены (раздел 3, 6).

## 9. Справочник скриптов

### 9.1. Общие правила управляющих скриптов

- Пять скриптов (`generate-server-env.ps1`, `add-client.ps1`, `remove-client.ps1`, `make-client-config.ps1`, `sync-servers.ps1`) лежат в `scripts\`, требуют `-Mode VPN|SEG` и передают управление в `scripts\seg\*.ps1` (режим SEG) или выполняют режим VPN сами (раздел 3).
- Недостающие аргументы (имя клиента, цель `sync`) скрипт спрашивает через `Read-Host`; без интерактивного ввода их нужно указывать явно.
- **Лишние и неверные аргументы.** Неизвестный параметр (например, `-Check` у `add-client.ps1`), лишний позиционный аргумент, неверное значение `-Mode` — ошибка привязки параметров PowerShell, код `-1`, действий нет. Аргумент, который у скрипта существует, но в режиме SEG не используется (`СЕРВЕР` у `add-client.ps1` и `make-client-config.ps1`), **вызывает ошибку** «SEG mode has a single gateway: the server argument is not used» (код 1), а не игнорируется. У `sync-servers.ps1 -Mode SEG` допустима только цель `all`, иная — ошибка (код 1).
- **Коды выхода.** `0` — успех, а также отмена пользователем (ответ «нет» пишет `CANCELLED`/`Nothing changed`); `1` — ошибка; `2` — только у `sync-servers.ps1`: `-Check` нашёл, что нужно привести в порядок (раздел 10.2).
- Все действия записываются в `logs/amnezia.log`; секреты в журнал и на экран не выводятся. Управляющие скрипты нельзя запускать параллельно.

### 9.2. `generate-server-env.ps1`

Синтаксис (обозначения: `[ ]` — необязательный элемент, `|` — выбор одного значения; блок не предназначен для копирования):

```text
generate-server-env.ps1 -Mode VPN|SEG [-Force] [-NoBackup] [-Restore]
```

Примеры (выполняются как есть из корня проекта):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\generate-server-env.ps1 -Mode SEG
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\generate-server-env.ps1 -Mode SEG -Restore
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\generate-server-env.ps1 -Mode SEG -Force -NoBackup
```

| Параметр | Действие |
|---|---|
| `-Mode` | `SEG` — `config/seg.env`, `VPN` — `config/server.env`; файлы независимы, второй режим «чужой» файл не читает (SEG читает `server.env` только ради сети клиентов VPN для проверки пересечения адресов) |
| `-Force` | пропускает вопрос «Generate a new seg.env and replace the existing one?» (при `-Restore` — «Replace the current seg.env with the backup?»); если файла нет, вопрос не задаётся |
| `-NoBackup` | не создавать новую копию текущего файла (уже существующие копии `config\*.bak` не удаляются: при компрометации удалите их вручную, в них остаются старые приватные ключи) |
| `-Restore` | вместо генерации восстановить самую свежую копию `*.bak` (проверяется валидатором; нет копий или копия повреждена — ошибка) |

Комбинации допустимы все. `-Restore` без `-NoBackup` сохраняет текущий файл как новую копию, поэтому повторный `-Restore` отменяет предыдущий; `-Restore -NoBackup` текущий файл не сохраняет. Копии хранятся три последние, без шифрования: при компрометации используйте `-NoBackup` и удалите уже существующие `config\*.bak`.

- **Читает:** `tools\sing-box.exe` и `awg.exe` (проверяются до подтверждения), существующий `seg.env` (сохраняются нечувствительные настройки: имя и dest REALITY, flow, fingerprint, сеть, порт и интерфейс backhaul, `RandomTrailers`, метки, `SEG_UNMATCHED_POLICY`; нечитаемый файл — значения по умолчанию).
- **Создаёт:** `config\seg.env` (`server.env` в режиме VPN), `config\*.bak`. Секреты (REALITY, ключи и PSK backhaul, параметры AmneziaWG) создаются заново при каждой генерации.
- **Серверы:** не затрагивает. После генерации или `-Restore` нужен `sync-servers.ps1 -Mode SEG all` (применять к паре целиком: backhaul работает только при совпадении ключей обеих сторон), а профили клиентов SEG пересоздаются (меняются ключ REALITY и `short_id`; UUID клиентов не затрагиваются).
- **Проверка:** результат проверяется валидатором до замены, при ошибке файл не меняется, копия создаётся только после успешной проверки.

### 9.3. `add-client.ps1`

Синтаксис (`[ ]` — необязательный элемент; блок не предназначен для копирования):

```text
add-client.ps1 -Mode SEG [ИМЯ]
add-client.ps1 -Mode VPN [ИМЯ] [СЕРВЕР]
```

Примеры:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\add-client.ps1 -Mode SEG laptop-anna
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\add-client.ps1 -Mode VPN laptop-anna vpn-01
```

- **SEG:** создаёт запись `clients/seg/ИМЯ.json` со случайным UUID и профиль `clients/generated/seg/ИМЯ.json` с `ИМЯ.meta.json`. Без имени спрашивает «Client name». Сначала проверяет конфигурацию (`seg.env`, `seg-list.json`, пара узлов в `servers.txt`), строит и проверяет профиль (структура и `sing-box check`), затем спрашивает «Create client?» и только после подтверждения пишет файлы (запись, затем профиль; при сбое запись удаляется). Отказывается работать, если клиент уже есть или рядом лежат файлы профиля без записи.
- **VPN:** создаёт клиента AmneziaWG: ключи, PSK, постоянный `clients/ИМЯ.conf` и peer в шаблоне; `СЕРВЕР` задаёт начальный `Endpoint` (при одном включённом сервере выбирается сам, при нескольких запрашивается); адреса выдаются из /24; спрашивает «Create client?».
- **Серверы:** не затрагивает. UUID (SEG) или peer (VPN) попадают на узлы только после `sync-servers.ps1`.
- **Имя:** раздел 8.4. UUID на экран и в журнал не выводится; профиль содержит UUID — передавайте его только по защищённому каналу.

### 9.4. `remove-client.ps1`

Синтаксис (`|` — выбор одного значения, `[ ]` — необязательный элемент; блок не предназначен для копирования):

```text
remove-client.ps1 -Mode SEG|VPN [ИМЯ]
```

Пример:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\remove-client.ps1 -Mode SEG laptop-anna
```

- **SEG:** удаляет профиль `clients/generated/seg/ИМЯ.json`, `ИМЯ.meta.json` и запись `clients/seg/ИМЯ.json` (профиль первым: при сбое запись остаётся, команду можно повторить). Имя ищется без учёта регистра и до использования в путях проверяется. Спрашивает «Remove client?». Нет клиентов — ошибка «There are no SEG clients». Если не остаётся включённых клиентов, выводится предупреждение.
- **VPN:** удаляет peer, `clients/ИМЯ.conf` и `clients/generated/ИМЯ/`; спрашивает «Remove client?».
- **Серверы:** не затрагивает: **доступ прекращается только после `sync-servers.ps1`** (SEG: убирает UUID из пользователей `sing-box`, активные соединения клиента завершаются перезапуском). До `sync` UUID остаётся действующим.

### 9.5. `make-client-config.ps1`

Синтаксис (`[ ]` — необязательный элемент; блок не предназначен для копирования):

```text
make-client-config.ps1 -Mode SEG [ИМЯ]
make-client-config.ps1 -Mode VPN [ИМЯ] [СЕРВЕР]
```

Примеры:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\make-client-config.ps1 -Mode SEG laptop-anna
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\make-client-config.ps1 -Mode VPN laptop-anna vpn-01
```

- **SEG:** создаёт или пересоздаёт профиль `clients/generated/seg/ИМЯ.json` и `ИМЯ.meta.json`. Перед запросом имени выводит состояние профилей всех клиентов (раздел 8.4). Профиль строится из шаблона, `seg.env`, `seg-list.json`, `servers.txt` и UUID, проверяется (структура и `sing-box check`) и записывается через временные файлы. Устаревший, отсутствующий и повреждённый профиль создаётся после «Create the profile?»; актуальный пересоздаётся только после «The profile is current. Recreate it anyway?» (по умолчанию «нет»: файл не меняется, код 0). Для отключённого клиента — ошибка (сначала включите клиента, раздел 7.4).
- **VPN:** создаёт производный профиль `clients/generated/ИМЯ/СЕРВЕР.conf`, меняя только `Endpoint`; работает только с включёнными серверами из `servers.txt`.
- **Серверы:** не затрагивает. Профиль нужно пересоздавать для каждого клиента отдельно.

### 9.6. `sync-servers.ps1`

Синтаксис (`[ ]` — необязательный элемент, `|` — выбор одного значения; блок не предназначен для копирования):

```text
sync-servers.ps1 -Mode SEG all [-Check]
sync-servers.ps1 -Mode VPN [СЕРВЕР|all] [-Check]
```

Примеры:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-servers.ps1 -Mode SEG all -Check
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-servers.ps1 -Mode SEG all
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-servers.ps1 -Mode VPN all -Check
```

- **SEG:** приводит пару узлов к локальному источнику истины (этапы — раздел 10.1). Только цель `all`; без цели спрашивает «Target». Ошибка или недоступность одного узла останавливает обработку второго (`SKIPPED`). Подтверждение запрашивается один раз: «Reboot IP and continue the upgrade?» (если узлу нужна перезагрузка; «нет» оставляет узел `PENDING`). Hardening в режиме SEG отдельного подтверждения не требует.
- **`-Check`:** ничего не меняет ни локально, ни на узлах, не задаёт вопросов и ничего не загружает на узлы (проверочные скрипты передаются внутри команды `ssh`). Отчёт — раздел 10.2.
- **Читает:** весь локальный каталог проекта. **Пишет локально:** в режиме SEG только журнал (профили и `servers.txt` не меняются); режим VPN дополнительно приводит клиентские профили к `server.env` и мигрирует старый `servers.txt` (раздел 8.1).
- **Коды:** `0` — пара синхронизирована (или `-Check`: актуальна и профили в порядке), `1` — `ERROR`/`UNREACHABLE`, `2` — `-Check` нашёл, что нужно применить или исправить.

### 9.7. Внутренние скрипты узлов

Скрипты в `seg\` и `upgrade.sh` запускает `sync-servers.ps1`, копируя их в `/root` узла (проверочные `check-*.sh` передаются внутри команды `ssh`, на узле не сохраняются). Вручную их запускают только при диагностике, на узле, от `root`. Обозначения аргументов: `ИНТЕРФЕЙС` — имя интерфейса backhaul (`SEG_BACKHAUL_INTERFACE`); `BACKHAUL_IP_VPS1` и `BACKHAUL_IP_VPS2` — **внутренние адреса backhaul** (`SEG_BACKHAUL_VPS1`, `SEG_BACKHAUL_VPS2`); `PUBLIC_IP_VPS1` — **публичный** IP `seg-exit` из `servers.txt`; `VLESS_PORT` — TCP-порт `seg-gateway` из `servers.txt`; `BACKHAUL_PORT` — `SEG_BACKHAUL_PORT`; `MTU` — `SEG_BACKHAUL_MTU`.

| Скрипт | Вызывает | Роль | Аргументы | Ручной запуск |
|---|---|---|---|---|
| `upgrade.sh` | этап `upgrade` (оба режима) | оба узла | без аргументов; перезагрузку не делает, сообщает `REBOOT_REQUIRED` | допустим, идемпотентен |
| `seg/bootstrap-seg.sh` | этап `bootstrap` | оба | `seg-gateway ВЕРСИЯ SHA256` (версия `X.Y.Z`, SHA-256 пакета — 64 hex строчными) или `seg-exit` | для `seg-exit` допустим; на gateway нужен пакет `/root/.seg-sync/sing-box-ВЕРСИЯ-linux-amd64.tar.gz` |
| `seg/secure-seg.sh` | этап `hardening` | оба | `seg-gateway VLESS_PORT BACKHAUL_PORT PUBLIC_IP_VPS1 ИНТЕРФЕЙС` или `seg-exit ИНТЕРФЕЙС BACKHAUL_IP_VPS1 BACKHAUL_IP_VPS2` | нежелателен: отключает вход по паролю (останавливается, если `authorized_keys` пуст), меняет UFW |
| `seg/check-node.sh` | `-Check` | оба | `seg-gateway VLESS_PORT BACKHAUL_PORT PUBLIC_IP_VPS1 ИНТЕРФЕЙС ВЕРСИЯ_SING_BOX` или `seg-exit ИНТЕРФЕЙС BACKHAUL_IP_VPS1 BACKHAUL_IP_VPS2` | допустим, только чтение |
| `seg/check-backhaul.sh` | этап проверки backhaul, `-Check` | gateway | `ИНТЕРФЕЙС BACKHAUL_IP_VPS1 BACKHAUL_IP_VPS2 PUBLIC_IP_VPS1 SEG_MARK [КОНФИГ_SING_BOX]` | допустим, только чтение (шлёт DNS-запросы через backhaul); пороги задают переменные окружения `SEG_MAX_HANDSHAKE_AGE` (150 с) и `SEG_HANDSHAKE_WAIT` |
| `seg/apply-seg.sh` | этапы настройки и откат | см. ниже | `apply-seg.sh ЭТАП [аргументы]` | см. ниже |
| `bootstrap.sh`, `secure.sh` | режим VPN | `vpn-server` | — | не для SEG-узлов |

#### `apply-seg.sh`: этапы

Скрипт применяет **кандидатов**, которые `sync-servers.ps1` заранее кладёт в `/root/.seg-sync/` (права 700): сам он ничего не рендерит. Любой этап проверяет кандидата (`nft -c`, `awg-quick strip`, `unbound-checkconf`, `sing-box check`, отсутствие нерешённых `{{VAR}}`), сохраняет прежние файлы и при ошибке возвращает их. Число аргументов проверяется строго: иначе выводится `Usage`.

| Этап и аргументы | Роль | Нужные файлы в `/root/.seg-sync/` | Что делает |
|---|---|---|---|
| `failclosed` | gateway | `seg-failclosed.nft`, `seg-failclosed.service` | ставит и перезагружает таблицу `inet seg_failclosed` (раздел 10.1, этап 7) |
| `routing ИНТЕРФЕЙС MTU` | gateway | — | только проверяет маршрутизацию и `rp_filter` (раздел 10.1, этап 8); при строгом `rp_filter` создаёт `/etc/sysctl.d/90-seg-rp-filter.conf` |
| `backhaul ИНТЕРФЕЙС MTU` | gateway и exit | `ИНТЕРФЕЙС.conf` (например, `awg-backhaul.conf`) | ставит конфигурацию backhaul, включает `awg-quick@ИНТЕРФЕЙС`, на exit также включает keepalive |
| `egress ИНТЕРФЕЙС BACKHAUL_IP_VPS1 BACKHAUL_IP_VPS2` | exit | `seg-exit.nft`, `seg-exit-fw.service`, `seg-exit-keepalive.service`, `unbound-seg.conf` | ставит firewall/NAT, `unbound`, keepalive |
| `singbox VLESS_PORT СЕРВЕР_REALITY` | gateway | `sing-box-config.json`, `sing-box.service` | ставит конфигурацию `sing-box`, перезапускает при изменении или замене бинарника, проверяет порт и REALITY (`СЕРВЕР_REALITY` — `SEG_REALITY_SERVER_NAME`). Требует активный fail-closed, пользователя `sing-box` и `/usr/local/bin/sing-box` |
| `snapshot РОЛЬ ИНТЕРФЕЙС` | оба | — | снимок управляемых файлов и состояния служб в `/root/.seg-snapshot` (`РОЛЬ` — `seg-gateway` или `seg-exit`) |
| `restore РОЛЬ ИНТЕРФЕЙС` | оба | снимок | возвращает снимок (раздел 10.3) |
| `snapshot-drop` | оба | — | удаляет снимок |

Вручную допустим только `restore РОЛЬ ИНТЕРФЕЙС` при неудавшемся автоматическом откате (раздел 10.3), например `/root/apply-seg.sh restore seg-gateway awg-backhaul`. Остальные этапы вручную запускать нежелательно: без актуальных кандидатов они либо откажутся работать, либо применят устаревшие.

Библиотеки `scripts\lib\*.ps1` (`common.ps1`, `servers.ps1`, `segenv.ps1`, `seglist.ps1`, `segclients.ps1`, `segprofile.ps1`) подключаются другими скриптами и сами не запускаются; полезны для проверок вручную (например, `Read-SegList` в разделе 8.3).

## 10. Синхронизация SEG, `-Check` и откат

`sync-servers.ps1 -Mode SEG all` — единственная команда, которая что-то меняет на узлах. Она всегда проходит **все этапы подряд** (на готовой паре около 5 минут) и пишет много строк, в том числе вывод `apt-get`, но это не переустановка: узлы не перезагружаются без вашего подтверждения, пакеты остаются на месте, конфигурации применяются только при отличии от локального источника, а на настроенной паре меняется лишь то, что действительно отличается (например, `sing-box` при добавлении клиента). Исключения: `secure-seg.sh` при каждом прогоне перезапускает Fail2Ban, а `upgrade.sh` обновляет ОС (раздел 11.5).

### 10.1. Порядок применения пары

`sync-servers.ps1 -Mode SEG all` применяет пару в порядке из `SEG.md` (раздел 24): проверка локальной конфигурации, SSH, upgrade, установка пакетов, hardening, candidate-конфигурации, fail-closed, маршрутизация, backhaul gateway, firewall/NAT/DNS и backhaul exit, проверка backhaul, `sing-box`, итоговая проверка. Каждый этап выполняется на обоих узлах (или на своей роли) и проверяет результат; ошибка или отказ останавливают прогон. Нумерация списка ниже — по этапам этого раздела (она не совпадает с нумерацией шагов в `SEG.md`):

1. Проверка локальной конфигурации: наличие `config/seg.env` (его создаёт `generate-server-env.ps1 -Mode SEG`), `config/seg-list.json`, шаблонов `seg/templates/`, `seg/sing-box.sha256`; валидация `seg.env` и `seg-list.json`; `servers.txt` должен быть в текущем формате (при старом формате сначала один раз выполните `sync-servers.ps1 -Mode VPN`) и содержать ровно один включённый `seg-gateway` и один `seg-exit`.
2. SSH к обоим узлам (`StrictHostKeyChecking=yes`, host key узла нужно сверить вручную, как в разделе 5.2). Если недоступен один узел, второй не обрабатывается.
3. `upgrade.sh` на каждом узле (сначала `seg-gateway`, затем `seg-exit`); на настроенном узле он тоже выполняется. Если нужна перезагрузка, скрипт спрашивает «Reboot IP and continue the upgrade?»: ответ «нет» оставляет узел `PENDING`, а следующий узел `SKIPPED`. Перезагрузка узла кратковременно прерывает работу SEG (backhaul восстанавливается сам; службы стартуют после загрузки).
4. `bootstrap-seg.sh` на каждом узле (пакеты и подготовка роли, без конфигураций и служб SEG; идемпотентен): на обоих — AmneziaWG (PPA, DKMS, `modprobe`; добавление PPA при временном отказе Launchpad повторяется до 3 раз с паузой 25 с, остальные ошибки не повторяются, при исчерпании попыток этап завершается ошибкой, повторите `sync` позже) и `nftables`, каталоги `/etc/seg` и `/etc/amnezia/amneziawg`; интерфейс `awg0` не создаётся, backhaul `awg-backhaul` настраивается отдельными этапами. На `seg-gateway` — `sing-box` из пакета `tools\sing-box-1.14.4-linux-amd64.tar.gz`: пакет проверяется на ноутбуке по `seg\sing-box.sha256`, копируется в `/root/.seg-sync/` (только если на узле нет бинарника нужной версии: ноутбук сначала читает версию на узле, так что на настроенном узле пакет не копируется и этап быстрее), на узле хэш проверяется ещё раз (его передаёт скрипт), после чего бинарник и версия проверяются и `sing-box` ставится в `/usr/local/bin` (атомарная замена; уже установленная та же версия не переустанавливается), создаются системный пользователь `sing-box` и каталог `/etc/sing-box`. На `seg-exit` — `unbound` и `unbound-anchor` (с `root.key`), `net.ipv4.ip_forward=1`. Пакет после установки удаляется из `/root/.seg-sync/`.
5. `secure-seg.sh` на каждом узле (hardening): вход по SSH только по ключу, Fail2Ban, автообновления, UFW. Правила роли помечены комментарием `seg:`; при повторном запуске скрипт добавляет правила текущих параметров, затем удаляет помеченные правила, которых в новом наборе нет (смена порта или IP), остальные правила не трогает и предупреждает (`WARN`) о правилах вне набора SEG. `seg-gateway`: `22/tcp`, `TCP` порт VLESS из `servers.txt` и `UDP` порт backhaul только с публичного IP `seg-exit`. `seg-exit`: `22/tcp`, DNS (tcp и udp 53) из `awg-backhaul` от `SEG_BACKHAUL_VPS2` к `SEG_BACKHAUL_VPS1` и маршрут (`ufw route`) от `SEG_BACKHAUL_VPS2` из `awg-backhaul` во внешний интерфейс; входящие сервисные порты не открываются (без `ufw route` и правил DNS UFW блокирует их независимо от таблицы `seg_exit`). Политика UFW: входящие и маршрутизируемые запрещены, исходящие разрешены. Перед запуском проверьте, что SSH-ключ установлен: скрипт отключает вход по паролю и останавливается, если `authorized_keys` пуст. В отличие от режима VPN подтверждение перед hardening не запрашивается: порты открываются по роли заранее, проверять нечего.

6. Candidate-конфигурации (шаблоны `seg/templates/`, подстановка `{{VAR}}` значений `seg.env` и IP из `servers.txt`, ошибка при нерешённой переменной) формируются до изменения узлов.
7. Fail-closed на `seg-gateway` (`seg\apply-seg.sh failclosed`): таблица nftables `inet seg_failclosed` из `/etc/seg/seg-failclosed.nft` и юнит `seg-failclosed.service` (включён, стартует раньше сети, `sing-box` и backhaul, не зависит от UFW). Правило: пакет с меткой `SEG_MARK` не уходит ни в какой интерфейс, кроме backhaul (`drop`, со счётчиком); метку получает только selected outbound `sing-box`. Дополнительно блокируется исходящий tcp/25 не через backhaul и ведётся счётчик `unmatched_direct` (страховочный DIRECT, метка `SEG_UNMATCHED_MARK`). Применение: кандидат проверяется `nft -c`, прежние файлы сохраняются, новая таблица загружается через `systemctl reload` (одна транзакция nftables, момента без правила нет; `restart` удалил бы таблицу), результат проверяется по загруженным правилам. При ошибке прежние файлы и таблица восстанавливаются; при первой установке неудачного кандидата узел остаётся без новой конфигурации. Неизменённая конфигурация не перезагружается. Перезагрузка таблицы обнуляет счётчики. `ufw reload` таблицу не затрагивает (она отдельная от правил UFW), поэтому порядок «UFW, затем fail-closed» не требуется и после `ufw reload` ничего перезапускать не нужно; `secure-seg.sh` дополнительно проверяет, что таблица на месте.

8. Маршрутизация selected-трафика на `seg-gateway` (`seg\apply-seg.sh routing`). Отдельная таблица маршрутизации и `ip rule` не используются: selected outbound `sing-box` привязан к интерфейсу backhaul (`bind_interface`), а backhaul работает с `Table = off`. Этап проверяет, не меняя маршрутов: default route идёт через публичный интерфейс (а не через backhaul), на интерфейсе backhaul нет маршрутов кроме собственной подсети (иначе ошибка), посторонние правила `ip rule` дают предупреждение, MTU интерфейса равен `SEG_BACKHAUL_MTU` (расхождение — предупреждение: MTU применяет этап backhaul). Фильтр обратного пути (`rp_filter`) не должен быть строгим: эффективное значение — большее из `all` и значения интерфейса (ещё не созданный интерфейс наследует `default`). Если оно равно `1`, скрипт создаёт `/etc/sysctl.d/90-seg-rp-filter.conf` (`all` и `default` в `2`, loose) и применяет значения; на Ubuntu 24.04 уже `2`, файл не создаётся. MSS clamp не нужен (MSS выводится из MTU интерфейса, к которому привязан сокет).

9. Backhaul на `seg-gateway` (`seg\apply-seg.sh backhaul`): конфигурация `/etc/amnezia/amneziawg/awg-backhaul.conf` (права 600, содержит ключ backhaul и PSK, в журнал не выводится) из шаблона `awg-backhaul-vps2.conf.template`; интерфейс `awg-quick@awg-backhaul` включён в автозапуск. VPS2 слушает `SEG_BACKHAUL_PORT`, `Endpoint` VPS1 не задаётся (VPS1 сам инициирует соединение), `Table = off` (маршруты не создаются), `MTU = SEG_BACKHAUL_MTU`, пир VPS1 с `AllowedIPs = 0.0.0.0/0` (при `Table = off` это не создаёт default route; `::/0` добавляется только после включения IPv6 в SEG). UDP-порт открыт в UFW только для публичного IP `seg-exit` (шаг 5). Перед установкой кандидат проверяется: нет нерешённых переменных, есть `Table = off`, нет `PostUp`, `PostDown`, `PreUp`, `PreDown`, `DNS`, `SaveConfig`, MTU совпадает с `seg.env`, разбор `awg-quick strip`. После установки сверяются состояние интерфейса, MTU, адрес, порт, публичный ключ пира и отсутствие лишних маршрутов. У `awg-quick` нет перезагрузки конфигурации, поэтому изменённая конфигурация применяется перезапуском интерфейса (selected-трафик на это время прерывается; `sing-box` перезапускать не нужно). Неизменённая конфигурация не трогается. При ошибке восстанавливается прежняя конфигурация и интерфейс; при неудачной первой установке не остаётся ни файла, ни включённой службы. Ключи и параметры AmneziaWG на VPS2 и VPS1 должны совпадать с `seg.env`: после `generate-server-env.ps1 -Mode SEG` туннель между узлами работает только после применения обеих сторон (VPS1 — этап 10 ниже), поэтому применяйте пару целиком.

10. Firewall, NAT, DNS и backhaul на `seg-exit` (`seg\apply-seg.sh egress`, затем `backhaul`). Этап `egress` ставит из шаблонов: таблицы nftables `inet seg_exit` и `ip seg_exit_nat` (`/etc/seg/seg-exit.nft`, юнит `seg-exit-fw.service`, загружается до backhaul), конфигурацию `unbound` на backhaul-адресе VPS1 (`/etc/unbound/unbound.conf.d/seg.conf`; слушает только `SEG_BACKHAUL_VPS1`, отвечает только `SEG_BACKHAUL_VPS2`) и юнит `seg-exit-keepalive.service`. Правила таблицы `seg_exit`: из backhaul в INPUT разрешён только DNS (tcp и udp 53) от `SEG_BACKHAUL_VPS2` к `SEG_BACKHAUL_VPS1`, остальное дропается (поэтому ping VPS1 по backhaul не проходит: состояние проверяется по handshake и DNS); в FORWARD разрешён только источник `SEG_BACKHAUL_VPS2`, запрещены private, loopback, CGNAT, link-local и metadata (`169.254.0.0/16`), multicast, публичный IP VPS1, пересылка между backhaul-интерфейсами и IPv6; NAT: masquerade адреса `SEG_BACKHAUL_VPS2` при выходе не через backhaul. Кандидаты проверяются (`nft -c`, `unbound-checkconf`, нерешённые переменные), прежние файлы сохраняются, таблицы загружаются через `systemctl reload` (одна транзакция), `unbound` перезапускается при изменении, затем проверяются таблицы, правила, прослушивание порта 53 на backhaul-адресе (udp и tcp) и `ip_forward`; при ошибке всё возвращается к прежнему состоянию. Затем этап `backhaul` ставит сторону VPS1 из `awg-backhaul-vps1.conf.template` (`Endpoint` VPS2 с `SEG_BACKHAUL_PORT`, `PersistentKeepalive = 25`, `AllowedIPs` пира — только `SEG_BACKHAUL_VPS2/32`, `Table = off`) и после запуска включает `seg-exit-keepalive.service` (`ping -i 5` на VPS2: без него после перезапуска backhaul на VPS2 туннель мог ждать до ~3 минут вместо ~19 секунд). `awg0` на VPS1 не создаётся, входящие сервисные порты наружу не открываются (VPS1 сам инициирует соединение). Правила UFW (DNS и `ufw route`) ставит шаг 5.

11. Проверка backhaul до запуска `sing-box` (`seg\check-backhaul.sh` на `seg-gateway`, только чтение). Скрипт выводит строки `CHECK ИМЯ=значение` (те же, что использует `-Check`) и `BACKHAUL_CHECK_OK`: `INTERFACE` (интерфейс поднят), `BACKHAUL_ADDRESS` (адрес `SEG_BACKHAUL_VPS2` на интерфейсе), `HANDSHAKE` (`FRESH age=…s`, `STALE` старше 150 секунд, `NONE`; при отсутствии свежего handshake скрипт до 60 секунд посылает DNS-запросы к VPS1, чтобы он начался), `BACKHAUL_DNS` (резолвер VPS1 отвечает через backhaul), `EGRESS_IP` (внешний адрес через `curl --interface` равен публичному IP `seg-exit`; пробуются три сервиса) и, когда конфигурация `sing-box` уже есть, `SELECTED_ROUTING` (outbound `seg-out` привязан к интерфейсу backhaul и несёт `SEG_MARK`, метку не использует другой outbound) и `UNMATCHED_DIRECT` (информация о страховочном DIRECT, не ошибка; смысл — раздел 2). При любой ошибке этап завершается ошибкой, узлы получают `ERROR`/`SKIPPED`, а `sing-box` не запускается и не меняется.

12. `sing-box` на `seg-gateway` (`seg\apply-seg.sh singbox`). Серверная конфигурация формируется на ноутбуке из `seg/templates/sing-box-vps2.json.template`: входящее VLESS + REALITY (TCP, порт `Port` gateway из `servers.txt`, `SEG_REALITY_*` из `seg.env`, handshake-сервер из `SEG_REALITY_DEST`), пользователи — все включённые клиенты `clients/seg/*.json` (пустой список допустим: `sing-box` запускается, но подключиться нельзя), sniffing (TLS SNI, QUIC), правила по `seg-list.json`: selected-ресурсы идут в outbound `seg-out` (привязан к `awg-backhaul`, метка `SEG_MARK`), остальное — в страховочный `direct` (метка `SEG_UNMATCHED_MARK`, счётчик `unmatched_direct`) или, при `SEG_UNMATCHED_POLICY=block`, в завершающее правило `reject`; DNS selected-доменов решает резолвер VPS1 через `seg-out`. Перед отправкой проверяется, что результат — корректный JSON; `sing-box check` выполняется на узле Linux-бинарником (Windows-сборка отклоняет `routing_mark`). Файл `/etc/sing-box/config.json` (`root:sing-box`, 640) содержит ключ REALITY и UUID и в журнал не выводится. Скрипт отказывается работать без активного fail-closed и без пользователя и бинарника `sing-box` (их готовит `bootstrap-seg.sh`); служба `sing-box.service` работает от пользователя `sing-box`. После запуска проверяется: служба включена и активна, процесс идёт от пользователя `sing-box`, порт слушается, неавторизованное TLS-соединение REALITY передаёт на handshake-сервер (виден настоящий сертификат для `SEG_REALITY_SERVER_NAME`). `sing-box` читает конфигурацию только при старте, поэтому изменённая конфигурация применяется перезапуском (клиенты переподключаются); неизменённая не перезапускается, кроме случая, когда работающий процесс запущен со старого файла (на узле установлена другая версия бинарника: `sing-box` читает файл при старте): `sync` перезапускает службу, а `-Check` показывает такой узел как `GATEWAY=DEGRADED` (`services: FAIL sing-box.service:old-binary`). При ошибке восстанавливается прежняя конфигурация; при неудачной первой установке `sing-box` остаётся остановленным и выключенным, fail-closed не затрагивается. После установки `check-backhaul.sh` запускается ещё раз вместе с проверкой `SELECTED_ROUTING` для установленной конфигурации.

Конфигурацию клиента (профиль) создают команды клиентов SEG (`add-client.ps1`, `make-client-config.ps1` в режиме SEG, раздел 9); `sync` их не создаёт, но показывает устаревшие профили в `-Check`.

13. Итоговая проверка пары: тот же read-only отчёт, что выдаёт `-Check` (раздел 10.2): `GATEWAY=READY`, `EXIT=READY`, `BACKHAUL=UP`, `HANDSHAKE=FRESH`, `SELECTED_ROUTING=OK`, `BACKHAUL_DNS=OK`, `EGRESS_IP` равен IP `seg-exit`, `FAIL_CLOSED=OK`, `SECURITY=OK`. Если всё в норме, оба узла получают статус `OK` и скрипт завершается кодом 0 («SEG pair synchronized successfully»); если итоговая проверка нашла расхождение или не смогла выполниться, узлы получают `ERROR`, а код выхода равен 1. `UNMATCHED_DIRECT` — информация и на статус не влияет.

Порядок и остановка. Этапы выполняются по парам: сначала один этап на обоих узлах (gateway, затем exit), ошибка или отказ на любом узле останавливает прогон, этот узел получает `ERROR` или `PENDING`, второй `SKIPPED`; следующие этапы не выполняются. Это значит, что `sing-box` не запускается и не меняется, пока не пройдены fail-closed и проверка backhaul. Откат при ошибке — ниже.

### 10.2. Режим проверки `-Check`

`sync-servers.ps1 -Mode SEG -Check all` ничего не меняет ни локально, ни на узлах, не задаёт вопросов и **ничего не загружает на узлы**: проверочные скрипты `seg/check-node.sh` и `seg/check-backhaul.sh` передаются внутри команды `ssh` и выполняются без сохранения на узле (только чтение; `check-backhaul.sh` лишь посылает DNS-запросы через backhaul). Кандидаты конфигураций рендерятся на ноутбуке во временный каталог только для сравнения хэшей SHA-256 с установленными файлами узлов; содержимое файлов и секреты не выводятся. Итог — отчёт полей:

| Поле | Значения и смысл |
|---|---|
| `GATEWAY`, `EXIT` | `READY` — пакеты, службы и правила на месте и установленные файлы совпадают с локальным источником; `CHANGES` — всё работает, но файл на узле отличается от локального (например, добавлен клиент или изменён `seg-list.json`: нужен `sync`); `DEGRADED` — что-то из установленного не работает (служба, таблица, пакет, интерфейс); `NEW` — на узле ничего не установлено |
| `BACKHAUL` | `UP` — интерфейс backhaul поднят с нужным адресом на обоих узлах, иначе `DOWN` |
| `HANDSHAKE` | `FRESH age=…s` (не старше 150 секунд), `STALE`, `NONE` (с точки зрения gateway) |
| `SELECTED_ROUTING` | `OK` — selected outbound `sing-box` привязан к интерфейсу backhaul и несёт `SEG_MARK`; `FAIL`; `NO_CONFIG` — конфигурации `sing-box` на узле нет; `NOT_CHECKED` |
| `BACKHAUL_DNS` | `OK` — резолвер VPS1 отвечает через backhaul |
| `EGRESS_IP` | внешний адрес через backhaul; должен равняться публичному IP `seg-exit`, иначе предупреждение (`NONE` — выхода нет) |
| `FAIL_CLOSED` | `OK` — служба и таблица `seg_failclosed` на месте, есть правило `drop` для помеченного трафика и счётчик; проверка пассивная (без остановки backhaul: активная проверка — на этапе тестирования) |
| `UNMATCHED_DIRECT` | число новых соединений страховочного DIRECT; ненулевое значение — предупреждение, а не ошибка (раздел 2) |
| `SEG_LIST_VERSION`, `SEG_LIST_HASH` | версия и SHA-256 локального `seg-list.json`; применён ли он на VPS2, показывает `GATEWAY` (хэш серверного конфига включает список) |
| `SECURITY` | `OK` — на обоих узлах вход по SSH только по ключу, UFW активен с запретом входящих и правилами роли, Fail2Ban работает; иначе `FAIL` с перечнем |

Кроме того, для каждого клиента выводится состояние профиля (раздел 8.4), а для каждого узла — версия ОС, ядро и признак ожидающей перезагрузки. Статус узла в итоговой сводке: `OK` или `CHANGES` (причины перечислены; проблемы самого backhaul относятся к `seg-gateway`), `ERROR`/`UNREACHABLE` — ошибка или недоступность. Код выхода: `0` — пара актуальна и профили в порядке, `2` — есть что исправить или применить, `1` — `ERROR`/`UNREACHABLE`. Чтобы привести пару в порядок, выполните `sync-servers.ps1 -Mode SEG all`; при `DEGRADED` сначала посмотрите причину в отчёте.

### 10.3. Откат при ошибке (rollback)

Перед применением конфигураций SEG (после upgrade, установки пакетов и hardening, перед fail-closed) на каждом узле делается **снимок** состояния (`apply-seg.sh snapshot`): копии управляемых файлов с правами и владельцем (fail-closed или firewall exit, юниты, конфигурация backhaul, конфигурация `sing-box`, drop-in `rp_filter`) и состояние служб (активна, включена). Снимок лежит в `/root/.seg-snapshot` (каталог `root` с правами 700; в нём ключи, поэтому он удаляется после успешного отката и после успешного прогона; хранится только последний).

Если после снимка этап завершился ошибкой (в том числе на втором узле, когда первый уже изменён), **оба узла автоматически возвращаются** к снимку (`apply-seg.sh restore`): восстанавливаются файлы, права и владельцы, загружается прежняя таблица fail-closed, перезапускаются только те службы, чьи файлы изменились (backhaul, `sing-box`, `unbound`), включённость и остановленность служб возвращаются, после чего всё сверяется со снимком (содержимое, режим, владелец, службы). Правила отката:

- **fail-closed не ослабляется:** если у узла до прогона fail-closed не было, новый остаётся на месте; selected-трафик не может выйти через публичный интерфейс VPS2 ни до отката, ни после;
- **первая установка:** если `sing-box` на узле не было, он остаётся остановленным и выключенным, его файлов нет; прочие файлы, которых не было до прогона, удаляются;
- **политика `SEG_UNMATCHED_POLICY`** не переключается: восстанавливается прежняя конфигурация `sing-box`, вместе с ней прежняя политика;
- **backhaul:** при ротации ключей, когда ошибка случилась после применения новых ключей на gateway, прежние ключи возвращаются на обоих узлах, и туннель продолжает работать на старых ключах.

Итог откатившегося прогона: узел, на котором случилась ошибка, получает `ERROR` (код выхода 1), второй — `ROLLED_BACK`. Если откат не удался, узел получает `ERROR` с пометкой `ROLLBACK FAILED`, снимок остаётся в `/root/.seg-snapshot` на узле, узел требует ручного вмешательства: проверьте состояние (`sync-servers.ps1 -Mode SEG -Check all`), при необходимости выполните на узле `/root/apply-seg.sh restore seg-gateway awg-backhaul` (или `seg-exit`) вручную. **Что не откатывается:** установка пакетов, обновление ОС и hardening (шаги до снимка, они идемпотентны и безопасны), состояние локальных файлов (`seg.env`, `clients/`: их при необходимости возвращают `generate-server-env.ps1 -Mode SEG -Restore` и копии), счётчик `unmatched_direct` (обнуляется перезагрузкой таблицы). Если ошибка случилась до снимка (проверка конфигурации, SSH, upgrade, пакеты, hardening), **конфигурация SEG на узлах не менялась** (fail-closed, backhaul, firewall exit, `sing-box`), откат не нужен. Но то, что выполнено до снимка, уже применено и остаётся: обновление ОС и пакетов (в том числе перезагрузка, если вы её подтвердили), установка бинарника `sing-box`, hardening (вход по SSH только по ключу, UFW, Fail2Ban). Эти шаги идемпотентны и безопасны, повторный `sync` продолжит с места остановки. Если итоговая проверка пары не прошла после применения всех этапов, автоматического отката нет (причиной может быть не конфигурация, например недоступный внешний сервис): конфигурация остаётся, снимок хранится на узлах до следующего прогона, а отчёт `-Check` показывает расхождение.

После ошибки: найдите причину в журнале (`logs/amnezia.log`), исправьте её и повторите `sync-servers.ps1 -Mode SEG all`: прогон идемпотентен и применит только то, что ещё не применено. Проверка пары без изменений — `-Check` (раздел 10.2).

## 11. Диагностика, восстановление и ограничения

### 11.1. Диагностика

Начинайте с `sync-servers.ps1 -Mode SEG all -Check` (раздел 10.2) и журнала `logs\amnezia.log`.

| Признак | Вероятная причина | Что делать |
|---|---|---|
| `GATEWAY=CHANGES` или `EXIT=CHANGES`, код 2 | файл на узле отличается от локального источника (добавлен клиент, изменён список или `seg.env`) | `sync-servers.ps1 -Mode SEG all` |
| `DEGRADED`, `FAIL_CLOSED=FAIL`, `services: FAIL …` | остановлена служба, нет таблицы или интерфейса | прочитайте причину в отчёте и выполните `sync`: он возвращает службу, интерфейс, таблицу |
| `sing-box.service:old-binary` | на узле заменён бинарник, процесс работает со старого файла | `sync` перезапускает службу |
| `UNREACHABLE` у узла, `SKIPPED` у второго | SSH недоступен | проверьте сеть, ключ и `known_hosts`; `sync` до первого изменения ничего не менял |
| `BACKHAUL=DOWN`, `HANDSHAKE=NONE` или `STALE` | `seg-exit` недоступен или ключи сторон не совпадают (`seg.env` применён не на обеих сторонах) | `sync` для пары целиком |
| `EGRESS_IP` не равен IP `seg-exit` | пир backhaul — другой узел (старый `seg-exit` ещё работает) | остановите или уничтожьте старый узел (раздел 11.2) |
| `SECURITY=FAIL` | нет правила UFW (например, после смены IP), включён вход по паролю | `sync` |
| этап `bootstrap`: ошибка `add-apt-repository` (HTTP 500 Launchpad) | временный отказ внешнего сервиса | скрипт повторяет команду до 3 раз; при исчерпании попыток повторите `sync` позже |
| клиент: ничего не открывается | UUID не добавлен на VPS2, профиль `STALE` по параметрам подключения, включён другой VPN, сеть блокирует TCP-порт VPS2 | раздел 6.2, `make-client-config.ps1 -Mode SEG` |
| клиент: selected-ресурс показывает адрес клиента | профиль не запущен или устарел по списку, DoH в браузере, соединение по IPv6 | раздел 6.5–6.6 |
| SSH к узлам обрывается (`banner exchange timed out`) | TUN-клиент на управляющем компьютере (Hiddify) перехватывает трафик | отключите его или добавьте маршрут к узлам мимо TUN |

Ping `seg-exit` по backhaul не проходит намеренно (в INPUT разрешён только DNS): состояние backhaul проверяют по handshake и DNS.

### 11.2. Замена VPS, смена IP и отказы

Параметры узлов (адрес, порт) берутся только из `servers.txt`, секреты из `config/seg.env`, профили клиентов из `clients/`: при замене узла секреты остаются прежними, если узел не скомпрометирован (иначе раздел 11.3).

- **Замена `seg-exit` (VPS1) или смена его IP.** Порядок важен: **старый узел останавливается до `sync`**. Пока он работает с теми же ключами backhaul, VPS2 продолжает принимать его пакеты даже после замены правила UFW, пир backhaul остаётся за старым адресом, и итоговая проверка пары покажет `EGRESS_IP` старого узла («expected …»).
  1. Создайте новый VPS (Ubuntu 24.04), выполните первый SSH-вход со сверкой host key (раздел 5.2).
  2. **Остановите старый узел**, пока его ключ хоста ещё в `known_hosts` (если он доступен): `ssh root@СТАРЫЙ_IP "systemctl disable --now seg-exit-keepalive awg-quick@awg-backhaul"` (`disable` не даст службам вернуться после его перезагрузки) или уничтожьте его у провайдера. С этого момента selected-запросы не проходят (fail-closed) до окончания шага 4.
  3. Замените IP в строке `seg-exit` в `servers.txt`.
  4. `sync-servers.ps1 -Mode SEG all`: новый узел проходит весь порядок развёртывания (раздел 10.1), на VPS2 правило UFW для UDP-порта backhaul переписывается на новый IP (старое `seg:backhaul-udp:ПОРТ:СТАРЫЙ_IP` удаляется как устаревшее, остальные правила не трогаются), в `seg-exit.nft` подставляется новый публичный IP VPS1. VPS1 сам устанавливает соединение, так что после запуска нового узла backhaul поднимается без действий на VPS2. Узел с другим ядром потребует перезагрузки: `sync` спросит подтверждение (раздел 10.1).
  5. Проверьте `sync-servers.ps1 -Mode SEG all -Check`: `EGRESS_IP` равен IP нового узла, код 0 (профили клиентов не менялись и остаются `CURRENT`).
  6. Только теперь, когда доступ к старому узлу больше не нужен, удалите его запись из `known_hosts` (`ssh-keygen -R СТАРЫЙ_IP`) и уничтожьте старый VPS у провайдера.
  
  Профили клиентов не меняются: в них нет адреса VPS1. Если старый узел скомпрометирован, одной замены IP недостаточно: смените ключи backhaul (раздел 11.3).
- **Замена `seg-gateway` (VPS2) на новый VPS или смена его IP.** Здесь порядок другой, чем для `seg-exit`: клиенты подключаются к шлюзу напрямую, поэтому их профили нужно заменить, а старый шлюз остановить только после этого (если шлюз скомпрометирован или должен быть отключён немедленно, остановите его сразу, клиенты потеряют доступ до получения новых профилей). Смена только порта на том же VPS — отдельный сценарий, следующий пункт.
  1. Создайте новый VPS (Ubuntu 24.04), выполните первый SSH-вход со сверкой host key (раздел 5.2).
  2. Замените IP в строке `seg-gateway` в `servers.txt` (`Port` оставьте прежним, если порт менять не нужно).
  3. `sync-servers.ps1 -Mode SEG all`: новый шлюз получает `sing-box`, fail-closed и backhaul, на VPS1 меняется `Endpoint` backhaul, на новом VPS2 правило UFW принимает backhaul только с IP VPS1. С этого момента VPS1 подключается уже к новому адресу, а старый шлюз сам backhaul не инициирует (VPS2 только слушает), поэтому по схеме selected-запросы через него не проходят (отдельно на двух живых шлюзах не проверялось).
  4. `-Check`: пара актуальна (`GATEWAY=READY`, `EXIT=READY`, `BACKHAUL=UP`, `SECURITY=OK`), а профили клиентов `STALE` («connection parameters changed»), поэтому код выхода **2**. Это ожидаемо.
  5. Для каждого клиента `make-client-config.ps1 -Mode SEG ИМЯ` и замена профиля на устройстве (раздел 6.6). Ключи REALITY, UUID клиентов и `seg-list` остаются прежними.
  6. Повторите `-Check`: код 0. Проверьте подключение устройств (раздел 6.5).
  7. Остановите старый шлюз, пока его ключ хоста ещё в `known_hosts`: `ssh root@СТАРЫЙ_IP "systemctl disable --now sing-box awg-quick@awg-backhaul"`, затем уничтожьте VPS у провайдера и удалите запись `ssh-keygen -R СТАРЫЙ_IP`. Пока старый шлюз работает, он принимает клиентов со старыми профилями и выпускает их неклассифицированный трафик со своего IP (страховочный выход).
- **Смена порта существующего `seg-gateway`** (тот же VPS и IP). Новый сервер не создаётся, старый не уничтожается, службы после проверки не останавливаются: узел один и тот же.
  1. Измените `Port` в строке `seg-gateway` в `servers.txt` (TCP-порт VLESS/REALITY, 1–65535; он не должен совпадать с портом SSH и с UDP-портом backhaul не конфликтует, протоколы разные).
  2. `sync-servers.ps1 -Mode SEG all`: `sing-box` на VPS2 получает новую конфигурацию и перезапускается (клиенты переподключаются, со старыми профилями подключиться больше нельзя), UFW открывает новый TCP-порт, а помеченное правило `seg:` со старым портом удаляется как устаревшее (раздел 10.1, шаг `secure-seg.sh`). Backhaul, ключи и IP не меняются, VPS1 не затрагивается.
  3. `-Check`: пара актуальна, профили клиентов `STALE` («connection parameters changed»), код **2**. Это ожидаемо.
  4. Для каждого клиента `make-client-config.ps1 -Mode SEG ИМЯ` и замена профиля на устройстве (раздел 6.6). Ключи REALITY, UUID и `seg-list` прежние.
  5. Повторите `-Check` (код 0) и проверьте подключение устройств (раздел 6.5). Если порт заблокирован сетью клиента, выберите другой (например, 443) и повторите шаги 1–5.
- **Переустановка ОС на том же IP:** `servers.txt` не меняется, но host key меняется: `ssh-keygen -R IP`, первый SSH-вход вручную со сверкой fingerprint, затем `sync-servers.ps1 -Mode SEG all` разворачивает узел заново с прежними секретами; профили клиентов остаются прежними.
- **Узел недоступен по SSH:** `sync` останавливается до первого изменения (`UNREACHABLE` у недоступного узла, `SKIPPED` у второго), ничего не меняя; пара обрабатывается только целиком. Недоступность самого узла для клиентов (reboot, остановка backhaul или `sing-box`) не открывает трафик без VPS1: selected-запросы не проходят, адрес VPS2 не используется (fail-closed).
- **Остановлен `sing-box`, потерян backhaul или таблица `seg_failclosed`:** `-Check` показывает `GATEWAY=DEGRADED` (или `FAIL_CLOSED=FAIL`) и завершается с кодом 2; `sync-servers.ps1 -Mode SEG all` возвращает службу, интерфейс или таблицу.
- **Ошибка в середине `sync`:** после этапа `snapshot` обе стороны возвращаются к прежнему состоянию (раздел 10.3).

### 11.3. Ротация ключей и компрометация

Секреты SEG лежат в `config/seg.env`: ключ REALITY (VPS2), `short_id`, ключи backhaul обеих сторон и PSK. UUID клиентов лежат в `clients/seg/` и в конфигурации `sing-box` на VPS2. `generate-server-env.ps1 -Mode SEG` пересоздаёт все секреты и параметры AmneziaWG backhaul сразу (UUID клиентов не затрагиваются); сохраняются только нечувствительные настройки. Старый `seg.env` по умолчанию сохраняется как `config/seg.env.<время>.bak`; при компрометации запускайте с `-NoBackup` и удалите существующие копии `config/seg.env.*.bak`: в них те же ключи.

Плановая ротация:

1. `generate-server-env.ps1 -Mode SEG` (подтвердить замену).
2. `sync-servers.ps1 -Mode SEG all` — применяет новые ключи на VPS2 и VPS1 (раздел 10.1). До этого шага узлы остаются на старых ключах; backhaul работает только при совпадении ключей обеих сторон, поэтому применять нужно к паре целиком.
3. Пересоздать профили клиентов SEG (меняются ключ REALITY и `short_id`) и передать их на устройства.

Если скомпрометирован **VPS2** (`seg-gateway`), у атакующего есть ключ REALITY, ключи backhaul, PSK, UUID всех клиентов и список `seg-list`. Синхронизировать со старым образом нельзя. Порядок (UUID нужно отозвать до `sync`, иначе новый узел получит и старые):

1. Пересоздайте VPS2 у провайдера с чистого образа. Если IP изменился, обновите строку `seg-gateway` в `servers.txt`. Удалите старый ключ хоста (`ssh-keygen -R IP`), выполните первый SSH-вход вручную со сверкой fingerprint (раздел 5.2).
2. Сгенерируйте новые секреты без копии: `generate-server-env.ps1 -Mode SEG -NoBackup`, и удалите существующие `config\seg.env.*.bak` (в них прежние ключи).
3. Перевыпустите клиентов: для каждого `remove-client.ps1 -Mode SEG ИМЯ`, затем `add-client.ps1 -Mode SEG ИМЯ` (новый UUID и новый профиль под тем же именем, раздел 7.5).
4. `sync-servers.ps1 -Mode SEG all`: новый VPS2 получает новые ключи REALITY и backhaul и **только новые UUID**, а VPS1 получает новые ключи backhaul (обе стороны применяются за один прогон). Старые UUID на узлах больше не существуют.
5. Передайте новые профили на устройства и замените ими прежние (раздел 6.6). Старые профили перестанут подключаться: UUID и ключи REALITY изменились.
6. Проверьте подключение каждого устройства (раздел 6.5) и `sync-servers.ps1 -Mode SEG all -Check` (ожидается код 0). Старый образ VPS2 уничтожьте у провайдера.

Если скомпрометирован **VPS1** (`seg-exit`), у атакующего есть ключ backhaul VPS1 и PSK, а также виден трафик selected-ресурсов, выходящий через него (адреса назначения и DNS-запросы); ключа REALITY и UUID на VPS1 нет. Порядок:

1. Пересоздайте VPS1 с чистого образа (при смене IP обновите `servers.txt`: фаервол VPS2 принимает backhaul только с IP VPS1), удалите старый ключ хоста и сверьте fingerprint при первом входе (раздел 5.2). Старый VPS1 остановите или уничтожьте до `sync` (раздел 11.2).
2. `generate-server-env.ps1 -Mode SEG -NoBackup` и удаление `config\seg.env.*.bak`.
3. `sync-servers.ps1 -Mode SEG all`: новые ключи backhaul применяются на обеих сторонах.
4. Генератор меняет и ключ REALITY, поэтому профили всех клиентов нужно пересобрать (`make-client-config.ps1 -Mode SEG ИМЯ`) и заменить на устройствах (раздел 6.6). UUID клиентов остаются прежними (на VPS1 их не было).
5. Проверьте `-Check` (код 0) и подключение устройств (раздел 6.5).

Если утёк весь **ноутбук**, известны все секреты проекта и SSH-ключ доступа к узлам. Порядок:

1. Создайте на безопасном компьютере новый SSH-ключ, добавьте его на оба узла (`authorized_keys`), удалите старый ключ с узлов; на утерянном ноутбуке отзовите доступ у провайдера, где возможно.
2. Пересоздайте оба узла с чистого образа (атакующий мог получить root). Старые узлы уничтожьте.
3. Выполните порядок для VPS2 (шаги 2–6 выше), он включает перевыпуск секретов и UUID всех клиентов.
4. После этого `-Check` пары даёт код 0, а профили на устройствах заменены.

### 11.4. Восстановление на другом компьютере

Нужны (всё это секреты: хранить только в зашифрованном виде):

- `servers.txt`;
- `config\seg.env` (без него узлы придётся пересоздавать с новыми ключами и выдавать клиентам новые профили);
- `clients\seg\` (записи клиентов с UUID);
- SSH-ключ доступа к узлам и `~\.ssh\known_hosts` (иначе первый вход придётся повторять вручную со сверкой host key).

`config\seg-list.json` лежит в git; `tools\` не копируется (скачивается заново, раздел 5.1: скрипты сверяют файлы с `seg\sing-box.sha256`); копии `config\seg.env.*.bak` и `clients\generated\` переносить не нужно.

Порядок:

1. Получите проект из git, положите на место секретные файлы (`servers.txt`, `config\seg.env`, `clients\seg\`), SSH-ключ и `known_hosts`.
2. Подготовьте `tools\` (раздел 5.1).
3. Проверьте пару: `sync-servers.ps1 -Mode SEG all -Check`. Ожидается: узлы актуальны (`GATEWAY=READY`, `EXIT=READY`, `BACKHAUL=UP`, `SECURITY=OK`), а профили клиентов показаны как `MISSING` (папку `clients\generated\` не копировали), поэтому итоговый код выхода **2** («client profiles needing attention»). Проверка ничего не меняет.
4. Создайте профили заново: `make-client-config.ps1 -Mode SEG ИМЯ` для каждого клиента (подтвердите «Create the profile?»). Профиль получится прежним (UUID и параметры подключения те же), профили на устройствах менять не нужно.
5. Повторите `sync-servers.ps1 -Mode SEG all -Check`: ожидается код 0.

Если `config\seg.env` утерян: `generate-server-env.ps1 -Mode SEG`, `sync-servers.ps1 -Mode SEG all` и новые профили всем клиентам (ключи REALITY изменились).

### 11.5. Обновления и эксплуатация

- **Прогон идемпотентен.** `sync-servers.ps1 -Mode SEG all` можно повторять после любой ошибки: он применяет только то, что ещё не применено.
- **Обновление ОС.** `upgrade.sh` выполняется на обоих узлах при каждом прогоне (перезагрузка только с вашего подтверждения «Reboot IP and continue the upgrade?»). Узел с другим ядром при `upgrade` потребует перезагрузки; перезагрузка узла кратковременно прерывает работу SEG, backhaul восстанавливается сам.
- **Версия `sing-box`** зафиксирована (1.14.4, хэши в `seg\sing-box.sha256`): скрипты останавливаются при несовпадении, а переход на другую версию — отдельное изменение проекта (хэши, шаблоны, повторная проверка), а не действие `sync`. Пакет на VPS2 копируется только если там нет бинарника нужной версии.
- **Fail2Ban.** `secure-seg.sh` при каждом `sync` перезапускает Fail2Ban: конфигурация, UFW и остальные службы остаются прежними, баны сохраняются, но счётчики «Total failed/banned» обнуляются.
- **SSH.** Короткая проверка имеет hard timeout 15 секунд; рабочие SSH/SCP-сессии используют keepalive и не ограничивают длительность upgrade и bootstrap. При обрыве SSH во время `upgrade.sh` скрипт ждёт возврата SSH и повторяет upgrade (до 4 попыток); `upgrade.sh` и `bootstrap-seg.sh` ждут блокировку apt/dpkg до 300 секунд. Добавление PPA AmneziaWG при временном отказе Launchpad повторяется до 3 раз с паузой 25 с.
- **Ручной `ufw reload`** таблицу `seg_failclosed` не затрагивает (она отдельная от правил UFW), ничего перезапускать после него не нужно.
- **Управляющий компьютер.** Если на нём включён full-tunnel клиент (например, AmneziaWG), SSH к узлам идёт через его туннель: это допустимо, но не отключайте и не перезапускайте туннель во время прогона.

### 11.6. Ограничения и риски

Подробнее — раздел «Риски и ограничения» в `SEG.md`.

- **DNS клиента:** `sing-box` работает в TUN-режиме. Домены из `seg-list` получают от клиента FakeIP-адреса (`198.18.0.0/15`), а настоящий запрос идёт через VPS2 и backhaul на DNS-резолвер VPS1, без запасного варианта на локальный резолвер. Остальные домены резолвятся напрямую и настоящих адресов не подменяют. Прямой DNS клиента на Windows — только DoH/DoT (порт 53 при `strict_route` блокируется, в том числе для самого `sing-box`).
- **Передача домена:** клиент передаёт на VPS2 доменное имя (VLESS destination = домен), а не IP, поэтому VPS2 сопоставляет ресурс по домену. Если ресурс из списка пришёл как IP, VPS2 восстанавливает домен по SNI (TLS, QUIC) и сверяет с `seg-list` по домену и CIDR.
- **IPv4 и IPv6:** профиль задаёт `dns.strategy = ipv4_only` и TUN только с IPv4-адресом. Проверено: AAAA для selected-доменов клиенту не выдаётся, selected-трафик идёт только по IPv4, пока IPv6-выход VPS1 не включён и не проверен. Не проверено (на тестовом канале IPv6 не было): AAAA для обычных доменов (поле глобальное, поэтому ожидается тот же результат) и поведение соединений по готовому IPv6-адресу без DNS: оно зависит от платформы и `strict_route` (по документации `sing-box` сеть, которую TUN не поддерживает, делается недоступной). Не рассчитывайте на «прямой IPv6» у клиента SEG без проверки на своём устройстве. IPv6 для SEG пока не реализован; для его включения нужно отдельно настроить и проверить: backhaul IPv6, MTU backhaul не ниже 1280 (при `RandomTrailers = on` и `S4 = 144` это требует пересмотра `S4` или отказа от случайного хвоста), `AllowedIPs = ::/0` на VPS2, адрес VPS2-пира на VPS1, маршрутизацию selected-трафика на VPS2, маршрутизацию на VPS1, fail-closed и DNS strategy.
- **QUIC (UDP/443)** к ресурсам из списка отклоняется, чтобы браузер перешёл на TCP.
- **Несовместимость:** клиент SEG (TUN) нельзя запускать вместе с активным full-tunnel клиентом AmneziaWG (kill-switch блокирует прямой трафик): на время работы SEG его отключают.

- **Неполный список:** сервис использует много доменов (для видео YouTube нужны `googlevideo.com`, `ytimg.com`, `ggpht.com`, `jnn-pa.googleapis.com`). Домен вне списка идёт напрямую и может быть недоступен из РФ; пополняйте `seg-list.json` (раздел 8.3).
- **DoH/DoT в приложениях** (например, встроенный в браузер) обходит доменную классификацию: его нужно отключить или перехватывать TUN.
- **ECH** скрывает SNI: домен на VPS2 восстановить нельзя, ресурс выбирается только по CIDR. Для таких сервисов в список нужно вносить диапазоны адресов.
- **Ресурс без домена и без CIDR**, переданный клиентом по IP, уходит напрямую через VPS2.
- **Страховочный DIRECT и `SEG_UNMATCHED_POLICY` (VPS2):** трафик, не вошедший в `seg-list` (домен, домен по SNI, CIDR), обрабатывается по политике из `seg.env`: `direct` (по умолчанию) выпускает его с публичного IP VPS2, `block` отклоняет. Политику меняют правкой `SEG_UNMATCHED_POLICY` в `config/seg.env` и `sync-servers.ps1 -Mode SEG all` (`sing-box` перезапускается, клиенты переподключаются; новая политика попадает в серверную конфигурацию как завершающее правило `reject`). Страховочный DIRECT не получает метку `SEG_MARK` и не использует backhaul; он помечается `SEG_UNMATCHED_MARK`, по которой nftables считает новые соединения (счётчик `unmatched_direct`: только число, без содержимого и имён), и в любом случае не может отправить исходящий tcp/25. При любой политике до проверки `seg-list` отклоняются loopback, private, link-local и metadata-адреса, сеть backhaul и собственный публичный IP VPS2 (соединение с ним доставлялось бы локально через loopback в обход UFW), в том числе домены, которые на них указывают.
- **`UNMATCHED_DIRECT`:** число новых соединений страховочного DIRECT с момента последней загрузки таблицы fail-closed (обнуляется при перезагрузке таблицы, перезапуске узла и применении нового кандидата fail-closed); выводится `check-backhaul.sh` и расширенным `-Check` как `CHECK UNMATCHED_DIRECT=<n>`. Ненулевое значение — не ошибка, а информация: клиенты направляют на VPS2 трафик не по `seg-list` (устаревший профиль клиента, ресурсы вне списка, браузерный DoH, ресурс по IP без домена). Рост значения после правки `seg-list` означает, что в списке не хватает доменов или диапазонов.
- **Риски страховочного выхода:** при `direct` VPS2 выпускает неклассифицированный трафик со своим российским IP; утёкший UUID превращает VPS2 в российский прокси. Политика `block` убирает этот риск, но тогда любой ресурс вне `seg-list`, отправленный на VPS2 (устаревший профиль, ошибка передачи домена), просто не открывается.
- **Утёкший UUID клиента** превращает VPS2 в российский прокси (страховочный выход); отзывается удалением клиента и синхронизацией.
- **Единые точки отказа:** падение backhaul или VPS1 делает selected-ресурсы недоступными (fail-closed: трафик не уходит с IP VPS2), падение VPS2 прекращает вход.
- **UDP-приложения** через VLESS (XUDP) на прототипе не проверялись.
- **Регион выходного IP** определяет поведение сервисов: у VPS1 на прототипе Cloudflare показал `loc=IN`; сервисы, зависящие от региона, увидят регион VPS1, а не клиента.
- **Ресурсы VPS2:** около 0,9 ГБ RAM и без swap (`sing-box` занимает около 55 МБ, но обновления и сборка DKMS идут с малым запасом).
- **Изменения у сервисов:** смена доменов, CDN или IP сервиса требует обновления `seg-list.json` (порядок — раздел 7.6).
- **Блокировки и обнаружение:** блокировка VPS2 прекращает вход selected-трафика, блокировка VPS1 — его выход; DPI может обнаружить или заблокировать VLESS/REALITY либо AmneziaWG.
- **Ошибки классификации:** сбой FakeIP/reverse mapping или передачи домена приводит к неверной классификации или срабатыванию страховочной политики.
- **MTU и MSS backhaul** задаются согласованно (`SEG_BACKHAUL_MTU` вычисляет генератор): при MTU по умолчанию 1420 внешние пакеты AmneziaWG фрагментируются.
- **Утечка через VPS2:** ошибка `bind_interface` или fail-closed могла бы выпустить selected-трафик с IP VPS2; поэтому `-Check` показывает `FAIL_CLOSED` и `SELECTED_ROUTING`, а `sync` не запускает `sing-box` без fail-closed.

## 12. Дополнительный режим VPN

Режим VPN управляет несколькими самостоятельными AmneziaWG-серверами (роль `vpn-server` в `servers.txt`). Он не связан с SEG: использует собственные файлы (`config/server.env`, `config/awg0.conf.template`, `clients/*.conf`), а SEG-узлы (`seg-gateway`, `seg-exit`) не затрагивает. Все команды режима запускаются с `-Mode VPN`.

### 12.1. Базовая модель

В режиме VPN узлы равноправны и заменяемы: это экземпляры одной конфигурации (в отличие от SEG, где узлы выполняют разные роли).

Локальный каталог проекта на Windows-ноутбуке — единственный источник истины. Все VPS равноправны, не синхронизируются друг с другом и считаются заменяемыми экземплярами одной конфигурации.

Общие для всех VPS: серверная пара ключей, VPN-сети, AWG-параметры и набор клиентов. Индивидуальные для VPS: публичный IP и UDP-порт из `servers.txt`.

Компрометация одного VPS раскрывает общую серверную пару ключей **и PSK всех клиентов** (они лежат в `awg0.conf` на сервере). Это принятый компромисс схемы ради простого переключения клиента только сменой `Endpoint`. Порядок действий при компрометации — в разделе 12.7.

### 12.2. Первая настройка проекта

В git лежат только примеры; рабочие файлы перечислены в `.gitignore`.

1. Скопируйте `servers.txt.example` в `servers.txt` (строки `vpn-server`) и `config/awg0.conf.template.example` в `config/awg0.conf.template` (peer добавляет `add-client.ps1`).
2. Создайте `config/server.env`: `generate-server-env.ps1 -Mode VPN` (образец `config/server.env.example` — только формат: ключи и параметры AWG в нём нули, копировать его как есть нельзя). Без `server.env` `sync-servers.ps1 -Mode VPN` не стартует.
3. Создайте первого клиента: `add-client.ps1 -Mode VPN КЛИЕНТ [СЕРВЕР]` (можно пропустить: при первой настройке нового VPS `sync` предложит это сам).
4. Подготовьте VPS (раздел 12.4) и выполните `sync-servers.ps1 -Mode VPN СЕРВЕР`.

### 12.3. Скрипты режима VPN

Общие правила скриптов — раздел 9.1; ниже подробности режима VPN.

- `generate-server-env.ps1 -Mode VPN [-Force] [-NoBackup] [-Restore]` — создаёт новый `server.env`: новую серверную пару ключей и случайные AWG-параметры (`Jc`, `Jmin`, `Jmax`, `S1–S4`, `H1–H4`). Сети и DNS фиксированы. При `RandomTrailers=on` используется `S1=S2=S3=S4`. Ключи и PSK клиентов не затрагиваются. Если `server.env` уже есть, скрипт просит подтверждение (`-Force` его пропускает) и перед заменой сохраняет текущий файл как `config/server.env.<время>.bak`. Копии **не шифруются** (защита — шифрование диска и `.gitignore`), хранятся три последние. `-NoBackup` отключает копию. `-Restore` возвращает самую свежую копию (текущий файл при этом сам сохраняется как копия, поэтому повторный `-Restore` отменяет предыдущий). После `-Restore` нужен `sync-servers.ps1 -Mode VPN all`, как и после генерации.
- `add-client.ps1 -Mode VPN [КЛИЕНТ] [СЕРВЕР]` — создаёт клиента, его ключи/PSK, постоянный `clients/CLIENT.conf` и peer в шаблоне. Имя: `A-Za-z0-9._-`. `СЕРВЕР` задаёт начальный `Endpoint`; при одном включённом сервере он выбирается сам, при нескольких — запрашивается. Адреса выдаются из сети /24. Перед созданием спрашивает «Create client?». VPS не затрагивает: затем нужен `sync-servers.ps1 -Mode VPN all`.
- `remove-client.ps1 -Mode VPN [КЛИЕНТ]` — удаляет клиента из локального источника истины (peer, `clients/CLIENT.conf`, `clients/generated/CLIENT/`). Перед удалением спрашивает «Remove client?». На VPS изменения попадают после `sync-servers.ps1 -Mode VPN all`.
- `make-client-config.ps1 -Mode VPN [КЛИЕНТ] [СЕРВЕР]` — создаёт производный профиль `clients/generated/КЛИЕНТ/СЕРВЕР.conf`, меняя только `Endpoint`. Работает только с серверами из `servers.txt` с `Enabled=true`.
- `sync-servers.ps1 -Mode VPN [СЕРВЕР|all] [-Check]` — главный оркестратор: проверяет состояние VPS, выполняет первоначальную настройку/ремонт и синхронизацию. `all` обрабатывает все включённые серверы по очереди. С `-Check` работает только на чтение (см. раздел 12.5).

### 12.4. Новый VPS

1. Создать Ubuntu 24.04 VPS и установить SSH public key для `root`.
2. Выполнить первый SSH-вход вручную и сверить fingerprint host key с данными провайдера. Автоматизация использует `StrictHostKeyChecking=yes`.
3. Добавить VPS в `servers.txt` (`Role=vpn-server`, `Type=amnezia`) с уникальным UDP-портом (`Enabled=true`).
4. Выполнить `sync-servers.ps1 -Mode VPN SERVER`. Скрипт всегда копирует `upgrade.sh`, `bootstrap.sh` и `secure.sh` в `/root`, определяет состояние и действует по нему:
   - `NEW` — сначала `upgrade.sh`. Если нужна перезагрузка, спрашивает «Перезагрузить VPS и продолжить upgrade?» и после перезагрузки повторяет upgrade. Затем «Upgrade завершён. Перейти к настройке AmneziaWG?» и, при отсутствии клиентов, «Создать первого клиента?». Отказ на любом из этих шагов не отменяет выполненный upgrade: сервер получает статус `PENDING`, повторный запуск продолжит с места остановки;
   - `DEGRADED` — предлагает восстановительный `bootstrap.sh` без `dist-upgrade`; после ремонта сервер остаётся `PENDING` до повторного запуска;
   - `READY` — обычная синхронизация (раздел 12.5).
5. После bootstrap скрипт спрашивает «VPN проверен и работает. Перейти к security hardening?». Если на образе провайдера UFW был активен (закрывая UDP-порт AWG), `bootstrap.sh` отключает его до hardening, иначе VPN нельзя проверить; `secure.sh` затем включает UFW снова с правилами для SSH и AWG. На уже защищённом сервере (восстановительный bootstrap) UFW не затрагивается. Пока hardening не применено, сервер доступен по SSH с паролем и без фаервола, поэтому не откладывайте проверку надолго. Сначала нужно проверить VPN с клиента (для сервера, не указанного в `clients/КЛИЕНТ.conf`, профиль делается `make-client-config.ps1 -Mode VPN`), и только потом отвечать «да». Ответ «нет» оставляет `PENDING`: повторный `sync-servers.ps1 -Mode VPN SERVER` обнаружит незавершённое hardening и снова предложит запустить `secure.sh`. Пустой ввод означает «нет».
6. `secure.sh` включает UFW (открыты SSH и AWG UDP-порт), Fail2Ban, автообновления и отключает вход по паролю.

### 12.5. Синхронизация

Локальные клиентские профили один раз за запуск приводятся к `server.env` (серверный `PublicKey`, DNS, все AWG-параметры; `Endpoint` не меняется). Если хотя бы один профиль изменился, все производные профили AmneziaWG (`*.conf` в `clients/generated/<клиент>/`) удаляются как устаревшие — их нужно создать заново `make-client-config.ps1 -Mode VPN`. Профили режима SEG (`clients/generated/seg/*.json` и `*.meta.json`) этим не затрагиваются: режим VPN удаляет только файлы `*.conf`. Затем скрипт сверяет `Endpoint` всех профилей с `servers.txt` и выводит предупреждение (`WARN`), если постоянный профиль указывает на адрес, которого нет в `servers.txt`, или на отключённый сервер, а производный профиль не совпадает с адресом своего сервера или относится к серверу, которого уже нет. Предупреждение ничего не исправляет и не останавливает синхронизацию. Если всё совпадает, выводится `Client profile endpoints match servers.txt`. Пустой список peer является допустимым состоянием для `READY`/`DEGRADED` и позволяет, в частности, синхронизировать удаление последнего клиента. Для каждого VPS формируется индивидуальный `awg0.conf` с его `ListenPort`.

Для сервера в состоянии `READY` скрипт спрашивает «Выполнить синхронизацию с локальной конфигурацией?». При «да» конфигурация передаётся во временный `/root/.amnezia-sync` и сравнивается с боевой. Если отличий нет, ничего не меняется. Если есть, спрашивает «Применить изменения?»: при «нет» сервер получает статус `SKIPPED` и ничего не применяется. При изменении `awg0.conf` интерфейс `awg0` полностью перезапускается, чтобы гарантированно применить ключ, порт и все AWG-параметры; временные файлы после операции удаляются.

Если меняется AWG-порт и UFW уже активен, новый UDP-порт открывается до перезапуска, а старый закрывается только после успешной проверки. При ошибке выполняется rollback.

Ошибка одного VPS не прекращает обработку остальных. В конце выводится сводка со статусами `OK`, `PENDING`, `SKIPPED`, `ERROR`, `UNREACHABLE`; при `ERROR`/`UNREACHABLE` код выхода равен 1. Все действия записываются в `logs/amnezia.log`; секреты в журнал не выводятся.

#### Режим проверки `-Check` (VPN)

`sync-servers.ps1 -Mode VPN СЕРВЕР|all -Check` ничего не меняет ни локально, ни на VPS и не задаёт вопросов: на сервер ничего не загружается (даже `upgrade.sh`, `bootstrap.sh`, `secure.sh`), локальные профили не переписываются и `clients/generated/` не удаляется. Скрипт определяет состояние сервера (`NEW`/`DEGRADED`/`READY`), сравнивает хэши `awg0.conf` и `awg-iptables.service` на VPS с локально собранными и проверяет, выполнен ли security hardening. Дополнительно сообщает, какие локальные профили отличаются от `server.env` и совпадает ли `Endpoint` с `servers.txt`.

Статус сервера: `OK` — всё актуально; `CHANGES` — нужны изменения (причины перечислены); `UNREACHABLE`/`ERROR` — SSH недоступен или ошибка. Код выхода: `0` — всё актуально, `2` — нужны изменения на каком-либо сервере или локальные профили отличаются от `server.env`, `1` — есть `ERROR`/`UNREACHABLE`. Предупреждения про `Endpoint` профилей и про отключённые серверы код выхода не меняют. Режим удобен перед `sync-servers.ps1 -Mode VPN all`, чтобы заранее увидеть, перезапустит ли синхронизация `awg0`, и при работе без интерактивного ввода.

Эталон здорового VPN-сервера выводится строкой `Check baseline: ИМЯ STATE=READY VPN=UP SECURITY=OK`: `STATE=READY` — AmneziaWG установлен, `awg0` и служба правил брандмауэра активны (поэтому `VPN=UP`; при другом состоянии `VPN=NOT_READY`), `SECURITY=OK` — hardening выполнен (иначе `FAIL`).

### 12.6. Клиенты

Каждое физическое устройство имеет собственные ключи, PSK и внутренние адреса. Один и тот же peer присутствует на всех VPS.

Постоянно хранится один `clients/CLIENT.conf`. Его `Endpoint` указывает на сервер, выбранный при создании клиента, и `sync-servers.ps1 -Mode VPN` его не меняет. Производный профиль для другого VPS хранится как `clients/generated/CLIENT/SERVER.conf` и отличается только `Endpoint = IP:PORT`.

Порядок действий:

- **Новый клиент:** `add-client.ps1 -Mode VPN КЛИЕНТ [СЕРВЕР]` → `sync-servers.ps1 -Mode VPN all` → передать `clients/КЛИЕНТ.conf` на устройство; для других VPS — `make-client-config.ps1 -Mode VPN КЛИЕНТ СЕРВЕР`.
- **Удаление клиента:** `remove-client.ps1 -Mode VPN КЛИЕНТ` → `sync-servers.ps1 -Mode VPN all`. Доступ прекращается только на тех VPS, где применён sync; недоступные или выключенные (`Enabled=false`) серверы сохранят peer до следующей синхронизации.
- **Профиль для другого VPS:** `make-client-config.ps1 -Mode VPN КЛИЕНТ СЕРВЕР`.
- **Смена IP или порта VPS:** изменить `servers.txt`, выполнить `sync-servers.ps1 -Mode VPN СЕРВЕР`, затем выдать клиентам обновлённые профили (`make-client-config.ps1 -Mode VPN`): `Endpoint` в `clients/КЛИЕНТ.conf` автоматически не обновляется. Устаревшие профили `sync-servers.ps1 -Mode VPN` покажет предупреждением при каждом запуске.

### 12.7. Сценарии эксплуатации

#### Замена или вывод VPS

- **Замена VPS (новый IP):** создать новый VPS, выполнить первый SSH-вход и сверить host key (раздел 12.4), указать новый IP в `servers.txt` и выполнить `sync-servers.ps1 -Mode VPN СЕРВЕР` — пройдёт путь `NEW`. Старую запись удалить: `ssh-keygen -R СТАРЫЙ_IP`. Клиентам выдать новые профили (`make-client-config.ps1 -Mode VPN`), старые профили перестанут подходить: `-Check` и `sync` покажут предупреждение об устаревшем `Endpoint`.
- **Переустановка ОС на том же IP:** `servers.txt` менять не нужно, но ключ хоста меняется: удалить старую запись (`ssh-keygen -R IP`), выполнить первый SSH-вход вручную со сверкой fingerprint и запустить `sync-servers.ps1 -Mode VPN СЕРВЕР` (путь `NEW`). Профили клиентов остаются прежними.
- **Временное отключение:** `Enabled=false` в `servers.txt` исключает сервер из `sync-servers.ps1 -Mode VPN`, а в `add-client.ps1 -Mode VPN` и `make-client-config.ps1 -Mode VPN` его нельзя выбрать как `Endpoint`. Сервер остаётся на прежней конфигурации до включения и следующей синхронизации.
- **Вывод VPS:** убрать строку из `servers.txt`, удалить производные профили `clients/generated/*/СЕРВЕР.conf`, уничтожить VPS у провайдера, удалить запись из `known_hosts`.

#### Пересоздание серверных ключей

Требуется, если утёк `SERVER_PRIVATE_KEY` (компрометация VPS или ноутбука). `generate-server-env.ps1 -Mode VPN` создаёт новую серверную пару **и** новые AWG-параметры; ключи, PSK и адреса клиентов остаются прежними. По умолчанию старый `server.env` сохраняется как `config/server.env.<время>.bak`, чтобы можно было откатиться (`-Restore`). Если старый приватный ключ скомпрометирован, запускайте с `-NoBackup` и удалите уже существующие копии `config/server.env.*.bak`: в них остаётся тот же ключ.

1. Если скомпрометирован VPS, пересоздать его у провайдера с чистого образа и выполнить действия по замене VPS. Синхронизировать со старым образом нельзя: у атакующего был root.
2. `generate-server-env.ps1 -Mode VPN` (подтвердить замену; `-Force` пропускает запрос; `-NoBackup` — без копии старого файла, см. выше).
3. `sync-servers.ps1 -Mode VPN all` (предварительно можно выполнить `sync-servers.ps1 -Mode VPN all -Check`, чтобы увидеть, что будет изменено): приведёт `clients/*.conf` к новому `server.env`, удалит `clients/generated/*` и на каждом VPS после «Применить изменения?» перезапустит `awg0`. С этого момента старые клиентские профили перестают работать — выбирайте момент заранее.
4. Заново создать производные профили: `make-client-config.ps1 -Mode VPN КЛИЕНТ СЕРВЕР` для каждой пары. Делать только после шага 3, иначе профиль соберётся из устаревшего `clients/КЛИЕНТ.conf`.
5. Передать новые профили на все устройства и заменить старые.
6. Проверить, что все серверы получили изменения (`OK`, без `SKIPPED` и `UNREACHABLE`). Сервер, пропущенный или выключенный на шаге 3, остаётся на старом ключе и не принимает новые профили, пока не выполнена его синхронизация.

Если ротация прошла неудачно и серверы ещё не синхронизированы или нужно вернуть прежние ключи, выполните `generate-server-env.ps1 -Mode VPN -Restore`, затем `sync-servers.ps1 -Mode VPN all` и `make-client-config.ps1 -Mode VPN` для нужных пар.

Если был скомпрометирован VPS, считайте известными и PSK всех клиентов. Ротация серверной пары защищает от подмены сервера, но не меняет PSK. Для полной ротации перевыпустите клиентов: `remove-client.ps1 -Mode VPN` и `add-client.ps1 -Mode VPN` для каждого устройства, затем `sync-servers.ps1 -Mode VPN all` и раздача новых профилей. Если утёк весь ноутбук, перевыпуск клиентов обязателен: известны и ключи сервера, и ключи всех клиентов, а также SSH-ключ доступа к VPS (его тоже нужно заменить на серверах).

#### Восстановление на другом компьютере

Нужны: `servers.txt`, `config/server.env`, `config/awg0.conf.template`, `clients/`, а также SSH-ключ доступа к VPS и `~/.ssh/known_hosts` (иначе первый вход придётся повторять вручную и сверять host key). Копии `config/server.env.*.bak` переносить не нужно. Всё это — секреты: хранить только в зашифрованном виде. Производные профили `clients/generated/` можно не копировать: их создаёт `make-client-config.ps1 -Mode VPN`.

### 12.8. Обновления и эксплуатация

`upgrade.sh` устанавливает headers текущего ядра, `linux-headers-generic` и DKMS. Проверка состояния контролирует headers и DKMS-модуль AmneziaWG для наиболее нового установленного ядра.

IPv6 реализован через ULA + NAT66. Если на VPS нет рабочего глобального IPv6-маршрута, bootstrap выводит предупреждение: IPv6 через такой VPS может не работать.

Не запускать управляющие скрипты параллельно. После ручного `ufw reload` нужно проверить/перезапустить `awg-iptables.service`.
