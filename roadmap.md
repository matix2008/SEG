# Roadmap: добавление режима SEG в проект

## Правило сопровождения документации

`README.md` обновляется вместе с реализацией: каждый пункт, изменяющий поведение, формат файлов, параметры скриптов или эксплуатационный порядок, завершается правкой соответствующего раздела README в том же блоке изменений. Пункт не считается выполненным, пока README не отражает его результат.

Соответствие пунктов и разделов README:

| Пункты | Что отразить в README |
|---|---|
| 0 | расхождения с прототипом отражаются в `SEG.md` до начала автоматизации |
| 1, 12 | обязательный `-Mode`, новые примеры запуска, раздел 2 и 4 |
| 2–4, 30 | формат `servers.txt` (Role, Type, Port), миграция, совместимость `-Check`, раздел 3 и 5 |
| 5, 6 | `config/seg.env`, `SEG_*`, backup/restore по файлам, раздел 3 и 4 |
| 7, 22 | `seg-list.json`, версия и SHA-256, порядок изменения списка |
| 8, 19 | требования: локальный `sing-box 1.14.4`, раздел 2 |
| 9, 23–25 | SEG-клиенты, `clients/seg/`, generated-профили, раздел 3 и 4 |
| 10, 11, 21 | DNS-модель, FakeIP, передача домена, ограничения |
| 13–18, 27, 28 | новый SEG-узел, порядок развёртывания, rollback, раздел 5 и 6 |
| 14–15, 20, 38 | fail-closed, страховочный DIRECT, `SEG_UNMATCHED_POLICY` |
| 26 | `-Check` для VPN и SEG, интерпретация `UNMATCHED_DIRECT` |
| 41, 42 | замена VPS, смена IP, ротация ключей и UUID, компрометация, восстановление на другом ноутбуке, раздел 8 |

Итоговое покрытие README относительно `SEG.md` проверяет пункт 43.

## Статус выполнения

Статус каждого пункта фиксируется в таблице ниже и обновляется вместе с работой над пунктом. Значения: `не начат`, `в работе`, `выполнен`.

Пункт считается `выполненным`, когда одновременно:

1. сделано всё, что перечислено в тексте пункта (код, шаблоны, документ);
2. результат проверен: для пунктов реализации — запуском на VPS или локально, для пунктов этапа 3 — по описанным в них проверкам, с записью «что проверено — ожидание — факт»;
3. README отражает результат согласно таблице соответствия выше (для пунктов, которые меняют поведение);
4. пользователь подтвердил результат и зафиксировал изменения коммитом.

Пункты выполняются по порядку номеров; пункт, зависящий от невыполненного, не начинается. Исключение — пп. 29–42 (этап 3): они выполняются после соответствующих пунктов реализации.

| Пункт | Статус | Подтверждение |
|---|---|---|
| 0 Ручной прототип | в работе (ждёт подтверждения пользователя) | `SEG.md`, раздел 28; шаблоны в `seg\templates\` совпадают с рабочими конфигурациями прототипа |
| 1–11 (этап 1) | не начат | — |
| 12–28 (этап 2) | не начат | — |
| 29–43 (этап 3) | не начат | — |

При начале работы над пунктом строка с диапазоном разбивается на отдельные пункты.

## Принципы реализации

Цель — максимально использовать отлаженный код и минимизировать объём изменений в тестированных VPN-скриптах.

1. **Тестированный VPN-контур не рефакторится.** В `sync-servers.ps1`, `add-client.ps1`, `remove-client.ps1`, `make-client-config.ps1`, `generate-server-env.ps1` допускаются только: параметр `-Mode`, диспетчер (при `-Mode SEG` управление передаётся SEG-скрипту) и изменения, прямо необходимые для нового формата `servers.txt`. `bootstrap.sh`, `secure.sh`, `upgrade.sh` и `awg-iptables.service` в режиме VPN остаются побайтно прежними.
2. **SEG-логика находится в отдельных файлах**:

   ```text
   scripts\seg\sync-seg.ps1
   scripts\seg\add-client.ps1
   scripts\seg\remove-client.ps1
   scripts\seg\make-client-config.ps1
   scripts\lib\common.ps1
   seg\bootstrap-seg.sh
   seg\secure-seg.sh
   ```

   Общий интерфейс пользователя остаётся прежним: `-Mode SEG` на тех же пяти скриптах.
3. **Общая инфраструктура** (`Write-Log`, `Write-Utf8Lf`, `Read-EnvFile`, `Invoke-Remote`, `Test-Ssh`, `Copy-ToServer`, `Wait-SshAfterReboot`, `Invoke-UpgradeStage`, `Confirm-Action`) выносится в новый `scripts\lib\common.ps1` как копия и используется только SEG-скриптами. Дедупликация старых скриптов — отдельная необязательная задача после стабилизации SEG, с собственной регрессией.
4. **Переиспользуются**:
   - `upgrade.sh` без изменений на обоих SEG-узлах;
   - блок установки AmneziaWG (PPA, DKMS, `modprobe`) из `bootstrap.sh` копируется в `bootstrap-seg.sh`;
   - SSH hardening, Fail2Ban и автообновления из `secure.sh` копируются в `secure-seg.sh`;
   - механизм шаблонов `{{VAR}}` и проверка «Unresolved variables» (`Convert-Template`) для всех новых конфигураций: серверный и клиентский `sing-box`, `awg-backhaul` обеих сторон, таблица nftables;
   - генератор AWG-параметров, backup и restore из `generate-server-env.ps1` (параметризация по файлу и префиксу);
   - шаблон отката из `Invoke-Sync` (копия, `trap ERR`, восстановление) в удалённых SEG-скриптах.
5. **Валидация локально до отправки**: сгенерированные конфигурации `sing-box` проверяются локальной командой `sing-box check`.
6. **Один набор проверок backhaul** (внешний IP через `awg-backhaul`, handshake, DNS) используется и для `-Check`, и для тестов.

## Этап 0. Прототип на двух VPS

Цель: подтвердить ключевые предположения до написания автоматизации и зафиксировать рабочие конфигурации как шаблоны.

### Пункт 0. Ручной прототип

На двух VPS (VPS2 и VPS1) вручную настроить и проверить:

- `awg-backhaul`: инициирование с VPS1, handshake, `Table = off`, `PersistentKeepalive`;
- NAT и DNS resolver на VPS1;
- `sing-box` на VPS2 с VLESS + REALITY;
- `bind_interface = awg-backhaul` и `routing_mark = SEG_MARK`: поведение при остановленном backhaul (fail-closed);
- правило nftables «mark и `oifname != awg-backhaul` → DROP»;
- отдельная таблица маршрутизации `seg` и `ip rule` не нужны, достаточно `bind_interface` для привязанных сокетов (результат: `SEG.md`, раздел 13);
- sniffing на VPS2 и сопоставление домена с `seg-list` в `sing-box 1.14.4`;
- клиентский профиль `sing-box 1.14.4` в режиме TUN на Windows: FakeIP, DNS для selected-доменов через VPS1;
- страховочный DIRECT, блокировку loopback/private/metadata, tcp/25;
- `rp_filter`, MTU и MSS;
- установку `sing-box` из локально скачанного пакета с проверкой SHA-256 (без загрузки с GitHub на VPS2).

Результат:

- рабочие конфигурации, зафиксированные как шаблоны `{{VAR}}`;
- список отклонений от `SEG.md` (исправить документ до начала автоматизации);
- набор команд проверки (внешний IP, handshake, DNS), на основе которого строятся `-Check` и тесты.

Часть тестов этапа 3 (пп. 32, 33, 36, 38, 39) выполняется на прототипе и повторяется после автоматизации в сокращённом виде.

Прототип выполняется на отдельных VPS и не затрагивает рабочие VPN-серверы.

Результаты прототипа, отклонения от первоначального `SEG.md` и список непроверенного зафиксированы в `SEG.md`, раздел 28.

## Порядок выполнения

```text
1. Этап 0: прототип на двух VPS, шаблоны, правки SEG.md по итогам.
2. Пункты 1, 2, 4: -Mode (диспетчер) и формат servers.txt.
3. Пункты 3, 5–7: seg.env, seg-list.json, версии, хранение клиентов.
4. lib\common.ps1 и SEG-скрипты на шаблонах (пункты 12–20, 27, 28).
5. Клиентские SEG-скрипты и -Check (пункты 21–26).
6. Сокращённая регрессия VPN и приёмка SEG (пункты 29–42).
7. Сверка README с SEG.md (пункт 43).
```

README обновляется на каждом шаге.

## Этап 1. Подготовка

### Пункт 1. Ввести обязательный параметр `-Mode`

Поддерживаемые значения:

```powershell
-Mode VPN
-Mode SEG
```

Параметр добавить в:

- `sync-servers.ps1`;
- `add-client.ps1`;
- `remove-client.ps1`;
- `make-client-config.ps1`;
- `generate-server-env.ps1`.

Без `-Mode` выполнение завершается ошибкой.

Реализация: в каждом из пяти скриптов `-Mode VPN` продолжает выполнение прежнего кода, `-Mode SEG` передаёт управление соответствующему файлу в `scripts\seg\` (см. «Принципы реализации»).

Обновить:

- `README.md`;
- `CLAUDE.md`;
- примеры запуска;
- внутренние вызовы скриптов.

Режим `VPN` должен сохранить текущее протестированное поведение.

### Пункт 2. Изменить формат `servers.txt`

Новый формат:

```text
Name;IP;Port;Role;Type;Enabled
```

Роли:

```text
vpn-server
seg-gateway
seg-exit
```

Типы:

```text
amnezia
openvpn
sing-box
...
```

Пример:

```text
vpn-01;151.236.30.153;42157;vpn-server;amnezia;true
seg-ru;1.2.3.4;443;seg-gateway;sing-box;true
seg-eu;5.6.7.8;;seg-exit;amnezia;true
```

Семантика `Port`:

```text
vpn-server + amnezia
  → публичный UDP-порт VPN.

seg-gateway + sing-box
  → публичный TCP-порт VLESS/REALITY.

seg-exit
  → Port пустой.
```

Порт backhaul в `servers.txt` не хранится.

Валидатор `servers.txt` допускает пустой `Port` только для `seg-exit` и не включает его в проверку уникальности портов.

Обновить README: формат `servers.txt`, роли, типы, семантика `Port`.

### Пункт 3. Определить выбор серверов

Режим VPN использует только:

```text
Role = vpn-server
```

```text
Target = <server-name>
  → обработать выбранный vpn-server.

Target = all
  → обработать все enabled vpn-server.
```

SEG-серверы режимом VPN не обрабатываются.

Режим SEG требует:

```text
ровно 1 enabled Role = seg-gateway
ровно 1 enabled Role = seg-exit
```

```text
Target = all
  → обработать всю SEG-пару.
```

Индивидуальную синхронизацию узлов SEG в первой версии не использовать.

### Пункт 4. Реализовать миграцию `servers.txt`

Старый формат:

```text
Name;IP;Port;Enabled
```

преобразуется в:

```text
Name;IP;Port;Role;Type;Enabled
```

со значениями:

```text
Role = vpn-server
Type = amnezia
```

Миграцию выполняет только `sync-servers.ps1` в обычном (не `-Check`) запуске.

Перед миграцией:

- создать резервную копию;
- проверить новый файл;
- заменить исходный только после успешной проверки.

Миграция должна быть идемпотентной.

`-Check` ничего не записывает: старый формат он читает в режиме совместимости (`Role=vpn-server`, `Type=amnezia`) и сообщает «нужна миграция». Вывод `-Check` режима VPN на старом и новом формате совпадает.

Остальные скрипты при старом формате требуют предварительный запуск `sync-servers.ps1`.

Обновить README: порядок миграции и поведение `-Check`.

### Пункт 5. Добавить `config/seg.env`

Использовать отдельный файл:

```text
config/seg.env
```

`config/server.env` режимом SEG не читается и не изменяется. Код режима VPN (`Read-EnvFile`, проверка обязательных параметров, шаблоны) не затрагивается.

Параметры имеют префикс:

```text
SEG_
```

Добавить:

```text
SEG_REALITY_PRIVATE_KEY
SEG_REALITY_PUBLIC_KEY
SEG_REALITY_SHORT_ID
SEG_REALITY_SERVER_NAME
SEG_REALITY_DEST
SEG_REALITY_FLOW
SEG_REALITY_FINGERPRINT

SEG_BACKHAUL_PRIVATE_KEY_VPS1
SEG_BACKHAUL_PUBLIC_KEY_VPS1
SEG_BACKHAUL_PRIVATE_KEY_VPS2
SEG_BACKHAUL_PUBLIC_KEY_VPS2
SEG_BACKHAUL_PSK
SEG_BACKHAUL_NETWORK
SEG_BACKHAUL_VPS1
SEG_BACKHAUL_VPS2
SEG_BACKHAUL_PORT
SEG_BACKHAUL_INTERFACE
SEG_BACKHAUL_MTU
SEG_BACKHAUL_JC
SEG_BACKHAUL_JMIN
SEG_BACKHAUL_JMAX
SEG_BACKHAUL_S1..S4
SEG_BACKHAUL_H1..H4
SEG_MARK

SEG_UNMATCHED_POLICY
```

Значения:

```text
SEG_BACKHAUL_INTERFACE=awg-backhaul
SEG_UNMATCHED_POLICY=direct   (допустимо: direct | block)
```

`SEG_MARK` не совпадает с fwmark AmneziaWG, метками UFW и `awg-iptables`; проверяется при генерации.

Backhaul использует отдельные:

- ключи;
- PSK;
- сеть;
- адреса;
- порт;
- AWG-параметры.

Параметры режима VPN не переиспользуются.

Добавить `config/seg.env.example` (образец формата без секретов) и внести `config/seg.env*` в `.gitignore`.

Обновить README: раздел «Локальные данные» и «Первая настройка проекта».

### Пункт 6. Разделить генерацию и backup параметров по режимам

```powershell
generate-server-env.ps1 -Mode VPN
```

изменяет только `config/server.env`.

```powershell
generate-server-env.ps1 -Mode SEG
```

изменяет только `config/seg.env`.

Backup и restore выполняются по файлам независимо:

```text
config/server.env.<время>.bak
config/seg.env.<время>.bak
```

Хранятся три последние копии каждого файла, без шифрования. `-NoBackup` и `-Restore` действуют только на файл выбранного режима.

REALITY x25519 keypair генерируется локальным `sing-box`.

UUID клиентов генерируются локально.

Реализация: `-Mode SEG` вызывает ту же логику генерации AWG-параметров, backup и restore, что и режим VPN, с параметризацией по файлу (`seg.env`) и префиксу (`SEG_BACKHAUL_`). Дополнительно добавляются только REALITY-пара, PSK и UUID.

Источник истины для секретов остаётся на ноутбуке.

Скрипт проверяет наличие локального `sing-box 1.14.4` и завершается понятной ошибкой, если его нет.

Обновить README: требования (локальный `sing-box`), описание `generate-server-env.ps1 -Mode`, правила backup, действия при компрометации (ротация REALITY, backhaul, UUID).

### Пункт 7. Добавить `config/seg-list.json`

`seg-list.json` является единственным источником selective routing rules.

Структура:

```text
version
groups
domains
domain_suffixes
cidrs
sources
```

Первая версия включает:

```text
GitHub
GitHub Copilot
ChatGPT / OpenAI
Facebook / Messenger
Telegram
```

Для файла вычисляется SHA-256.

Из `seg-list.json` генерируется sing-box `rule_set`.

Автоматическое внешнее обновление списка в первой версии не выполнять.

Обновить README: структура `seg-list.json`, порядок изменения списка, пересоздание клиентских профилей.

### Пункт 8. Зафиксировать версии

Сервер:

```text
sing-box 1.14.4
```

Эталонный клиент:

```text
sing-box 1.14.4
```

Hiddify не входит в обязательные критерии приёмки первой версии.

Обновить README: раздел «Требования» (локальный `sing-box 1.14.4`, версия клиента).

### Пункт 9. Определить хранение SEG-клиентов

VPN-файлы:

```text
clients/*.conf
```

не изменяются.

SEG-клиенты:

```text
clients/seg/<client>.json
```

Хранят:

- имя;
- UUID;
- enabled;
- дату создания.

Generated profiles:

```text
clients/generated/seg/<client>.json
clients/generated/seg/<client>.meta.json
```

`meta.json` содержит:

```text
segListVersion
segListSha256
serverConfigSha256
generatedAt
```

Пользователи sing-box на VPS2 формируются из:

```text
clients/seg/*.json
```

Обновить README: структура каталога `clients/`, правила именования, хранение и передача UUID.

### Пункт 10. Зафиксировать DNS-модель

Клиентский sing-box работает в TUN-режиме.

Для доменной классификации использовать FakeIP/reverse mapping.

FakeIP применяется только к доменам `seg-list`. Остальные домены резолвятся локально и FakeIP не получают.

Для selected-доменов:

```text
DNS
  → VLESS/REALITY
  → VPS2
  → awg-backhaul
  → DNS resolver VPS1
```

Для DIRECT-доменов:

```text
DNS → local/direct resolver клиента
```

На VPS2 разрешить служебный маршрут:

```text
VPS2_BACKHAUL_IP
  → VPS1_BACKHAUL_IP:DNS
  → awg-backhaul
```

Остальной доступ к backhaul network блокировать.

Для selected traffic первой версии:

```text
DNS strategy = ipv4_only
```

если глобальный IPv6 egress VPS1 не проверен.

Для прямых IP-подключений использовать CIDR-правила.

Приложенческий DoH/DoT должен быть отключён либо перехвачен TUN.

На VPS2 DNS раздельный:

```text
домен ∈ seg-list
  → DNS resolver VPS1 через awg-backhaul
     (domain_resolver selected outbound; без fallback на локальный резолвер)

домен ∉ seg-list
  → локальный резолвер VPS2
```

Обновить README: DNS-модель, ограничения DoH/DoT/ECH.

### Пункт 11. Зафиксировать доменную модель VLESS

Для selected domain клиент должен передавать до VPS2 доменное имя:

```text
domain
  → client rule
  → VLESS destination = domain
  → VPS2 rule by domain
```

Клиент не должен заменять selected domain на IP до формирования VLESS-запроса.

IP/CIDR-правила используются отдельно для прямых IP-подключений.

Для случая, когда клиент передал ресурс из `seg-list` как IP или без домена, на VPS2 включается sniffing (TLS SNI, QUIC) и повторное сопоставление с `seg-list` по домену и CIDR. Ограничение: при ECH домен недоступен, спасают только CIDR-правила.

---

## Этап 2. Разработка

### Пункт 12. Доработать `sync-servers.ps1`

Режим VPN:

```text
Role = vpn-server
```

Текущий сценарий сохраняется.

Режим SEG:

```text
VPS2 = Role seg-gateway
VPS1 = Role seg-exit
```

Сохранить:

- SSH;
- host-key validation;
- logging;
- upgrade;
- security;
- validation;
- summary;
- error handling;
- confirmation;
- rollback.

Реализация: `-Mode VPN` выполняет прежний код без изменений. `-Mode SEG` передаёт управление `scripts\seg\sync-seg.ps1`, который использует `scripts\lib\common.ps1` и существующие `upgrade.sh`, SEG-скрипты и шаблоны. Состояния `NEW`/`DEGRADED`/`READY` для SEG не воспроизводятся: применение SEG — идемпотентная сходимость по порядку пункта 27.

Для режима SEG `-Check` и общая логика описаны в пунктах 26–28.

Обновить README: описание `sync-servers.ps1 -Mode`, поведение `all`, разделы 5–6.

### Пункт 13. Реализовать `bootstrap-seg.sh` и `secure-seg.sh`

`bootstrap.sh` и `secure.sh` режима VPN не изменяются. Для SEG создаются отдельные скрипты, использующие общие блоки (копии):

- `bootstrap-seg.sh`: установка AmneziaWG (PPA, DKMS, `modprobe`), роль-зависимая настройка;
- `secure-seg.sh`: SSH hardening, Fail2Ban, автообновления, UFW с правилами роли.

`upgrade.sh` используется без изменений.

Поддержать:

```text
SEG + seg-gateway + sing-box
SEG + seg-exit + amnezia
```

Для:

```text
SEG + seg-exit + amnezia
```

не создавать клиентский VPN-интерфейс `awg0`.

Создаётся только:

```text
awg-backhaul
```

`secure-seg.sh` различает роли:

```text
seg-gateway
  → SSH;
  → TCP Port (VLESS/REALITY);
  → UDP SEG_BACKHAUL_PORT только от публичного IP seg-exit.

seg-exit
  → SSH;
  → входящие сервисные порты не открываются.
```

Отдельные скрипты создаются для SEG (по роли внутри), а не для каждого сочетания режим/роль; общие блоки не дублируются между SEG-скриптами.

Обновить README: что делают `bootstrap.sh`/`secure.sh` (VPN) и `bootstrap-seg.sh`/`secure-seg.sh` (SEG) в каждой роли.

### Пункт 14. Реализовать fail-closed на VPS2

До запуска sing-box создать отдельную таблицу nftables.

Selected outbound sing-box:

```text
bind_interface = awg-backhaul
routing_mark = SEG_MARK
```

Добавить:

```text
mark = SEG_MARK
AND oifname != awg-backhaul
  → DROP
```

Метку `SEG_MARK` получает только selected outbound. Страховочный DIRECT-трафик (пункт 20) метку не получает и не использует `awg-backhaul`.

Fail-closed:

- загружается раньше sing-box;
- не зависит от UFW;
- не удаляется при `ufw reload`;
- сохраняется после reboot.

Не создавать жёсткую systemd-зависимость sing-box от `awg-backhaul`.

Обновить README: fail-closed и порядок после `ufw reload`.

### Пункт 15. Реализовать маршрутизацию selected-трафика VPS2

По результатам прототипа (`SEG.md`, раздел 13) отдельная таблица `seg` и `ip rule` не используются: selected outbound привязывается к интерфейсу `bind_interface = awg-backhaul`, а метка `SEG_MARK` служит правилу fail-closed (пункт 14). Сохраняются требования fail-closed и правило nftables из пункта 14.

Backhaul работает с:

```text
Table = off
```

Основная таблица VPS2 не изменяется:

```text
main default
  → public interface VPS2
```

Служебный DNS-трафик к `VPS1_BACKHAUL_IP` идёт через selected outbound (`domain_resolver` на resolver VPS1 с `detour` через selected outbound).

Дополнительно:

- задать `rp_filter` (loose или отключён) для `awg-backhaul`, чтобы ответы из backhaul не отбрасывались;
- задать MTU `awg-backhaul` (`SEG_BACKHAUL_MTU`) и MSS clamp.

### Пункт 16. Реализовать backhaul на VPS2

Создать:

```text
interface = awg-backhaul
```

VPS2:

- слушает `SEG_BACKHAUL_PORT`;
- Endpoint VPS1 не задаётся;
- использует `Table = off`;
- принимает UDP `SEG_BACKHAUL_PORT` только от публичного IP VPS1.

Peer VPS1:

```text
AllowedIPs = 0.0.0.0/0
```

Для IPv6:

```text
AllowedIPs += ::/0
```

только после включения SEG IPv6.

`AllowedIPs = 0.0.0.0/0` не создаёт default route, поскольку используется `Table = off`.

### Пункт 17. Реализовать backhaul и egress на VPS1

VPS1:

- инициирует `awg-backhaul`;
- использует `PersistentKeepalive`;
- выполняет forwarding;
- выполняет NAT;
- запускает DNS resolver на backhaul-IP;
- не открывает входящие сервисные порты наружу; backhaul инициирует сам.

Peer VPS2:

```text
AllowedIPs = <VPS2_BACKHAUL_IP>/32
```

Для IPv6 — только конкретный backhaul IPv6 VPS2.

На VPS1:

```text
INPUT from awg-backhaul
  → DROP
```

кроме:

```text
source = VPS2_BACKHAUL_IP
destination = VPS1_BACKHAUL_IP
port = DNS
  → ALLOW
```

Через backhaul запретить доступ к:

- SSH;
- loopback;
- private networks;
- link-local;
- metadata;
- управляющим сетям VPS1.

FORWARD разрешить только в Internet.

Обновить README: роль `seg-exit`, backhaul, безопасность VPS1.

### Пункт 18. Проверить backhaul до запуска proxy

Проверить:

- handshake;
- возраст handshake;
- backhaul addresses;
- привязка selected outbound к `awg-backhaul`;
- DNS VPS1 через backhaul;
- Internet egress;
- внешний IP через backhaul = VPS1.

При ошибке sing-box не запускать.

### Пункт 19. Реализовать VPS2 VLESS/REALITY

Установить:

```text
sing-box 1.14.4
```

Пакет скачивается на ноутбук, проверяется по SHA-256 (хэш фиксируется в репозитории) и копируется на VPS2; загрузка с GitHub на VPS2 не используется.

Перед отправкой каждая сгенерированная конфигурация проверяется локально командой `sing-box check`.

Конфигурация формируется из шаблона `{{VAR}}` (механизм `Convert-Template` с проверкой «Unresolved variables»), полученного из прототипа (пункт 0).

Настроить:

```text
VLESS
REALITY
TCP
Port = servers.txt.Port
```

Параметры берутся из `SEG_*` (`config/seg.env`).

Пользователи формируются из:

```text
clients/seg/*.json
```

На входящем соединении включить sniffing (TLS SNI, QUIC).

### Пункт 20. Реализовать server-side routing и страховочный выход на VPS2

Правило:

```text
destination ∈ seg-list
  → selected outbound
  → awg-backhaul
  → VPS1

destination ∉ seg-list
  → SEG_UNMATCHED_POLICY:
      direct → DIRECT через VPS2   (по умолчанию)
      block  → BLOCK
```

Принадлежность к `seg-list` определяется по домену, sniffed-домену и CIDR. Серверный `seg-list` применяется независимо от версии клиентского профиля.

До проверки `seg-list` блокировать при любой политике:

- loopback;
- private networks;
- link-local;
- metadata addresses;
- backhaul network;
- локальные сети VPS2.

Исключение:

```text
VPS2_BACKHAUL_IP
  → VPS1_BACKHAUL_IP:DNS
  → ALLOW
```

Страховочный DIRECT:

- не получает `SEG_MARK` и не использует `awg-backhaul`;
- блокирует исходящий tcp/25;
- ведёт счётчик unmatched-соединений без содержимого и имён;
- счётчик отображается в `-Check` как `UNMATCHED_DIRECT`.

Отзыв UUID выполняется через `remove-client.ps1 -Mode SEG` и `sync`.

DNS на VPS2:

- selected-домены → resolver VPS1 через `awg-backhaul`, без fallback;
- остальные → локальный резолвер VPS2.

Обновить README: страховочный DIRECT, `SEG_UNMATCHED_POLICY`, смысл `UNMATCHED_DIRECT`, риски.

### Пункт 21. Реализовать клиентскую маршрутизацию

Правило:

```text
destination ∈ seg-list
  → VLESS/REALITY → VPS2

destination ∉ seg-list
  → DIRECT
```

Для selected domain:

```text
VLESS destination = domain
```

Для IP-подключений использовать CIDR.

Selected DNS направлять через SEG.

DIRECT DNS оставлять локальным.

Профиль:

- содержит `route.auto_detect_interface`, чтобы соединение с VPS2 не попадало в собственный TUN;
- не перехватывает управляющий трафик (SSH к VPS): адреса VPS не входят в `seg-list`.

Обновить README: клиентская схема, установка клиента, ограничения.

### Пункт 22. Реализовать контроль версии клиентского списка

Сохранять:

```text
segListVersion
segListSha256
```

`make-client-config.ps1 -Mode SEG` определяет устаревший профиль.

`sync-servers.ps1 -Mode SEG -Check all` сообщает об устаревших локальных профилях.

После изменения `seg-list.json` клиентские профили перегенерируются.

Серверный `seg-list` обновляется на VPS2 при `sync` независимо от клиентских профилей.

Обновить README: порядок изменения `seg-list.json` и раздачи профилей.

### Пункт 23. Доработать `add-client.ps1`

```text
-Mode VPN
  → текущее поведение.

-Mode SEG
  → создать UUID;
  → создать clients/seg/<client>.json;
  → обновить users sing-box;
  → сформировать профиль.
```

Реализация: `-Mode SEG` выполняется в `scripts\seg\add-client.ps1`; VPN-код не изменяется.

Обновить README: описание `add-client.ps1 -Mode`.

### Пункт 24. Доработать `remove-client.ps1`

```text
-Mode VPN
  → текущее поведение.

-Mode SEG
  → удалить clients/seg/<client>.json;
  → удалить generated profile;
  → удалить клиента из конфигурации VPS2 при sync.
```

Доступ клиента прекращается после `sync-servers.ps1 -Mode SEG all` (отзыв UUID).

Реализация: `scripts\seg\remove-client.ps1`.

Обновить README: описание `remove-client.ps1 -Mode` и порядок отзыва.

### Пункт 25. Доработать `make-client-config.ps1`

```text
-Mode VPN
  → текущий AWG profile.

-Mode SEG
  → полный sing-box 1.14.4 JSON profile.
```

Реализация: `scripts\seg\make-client-config.ps1`; профиль формируется из шаблона `{{VAR}}`, полученного из прототипа (пункт 0), и проверяется локально командой `sing-box check`. `seg-list.json` преобразуется в `rule_set` (`ConvertTo-Json -Depth`, запись через UTF-8 без BOM и LF).

Профиль содержит:

- TUN;
- VLESS;
- REALITY;
- VPS2 endpoint;
- UUID;
- public key;
- shortId;
- server_name;
- flow;
- fingerprint;
- `seg-list` rule_set;
- FakeIP;
- DNS routing;
- DIRECT route.

Обновить README: описание `make-client-config.ps1 -Mode`, импорт профиля в клиент.

### Пункт 26. Добавить `-Check`

Поддержать:

```powershell
sync-servers.ps1 -Mode VPN -Check ...
sync-servers.ps1 -Mode SEG -Check all
```

VPN baseline:

```text
STATE=READY
VPN=UP
SECURITY=OK
```

SEG baseline:

```text
GATEWAY=READY
EXIT=READY
BACKHAUL=UP
HANDSHAKE=FRESH
POLICY_ROUTING=OK
BACKHAUL_DNS=OK
EGRESS_IP=<VPS1-IP>
FAIL_CLOSED=OK
UNMATCHED_DIRECT=<n>
SEG_LIST_VERSION=<version>
SEG_LIST_HASH=<sha256>
SECURITY=OK
```

`-Check` не изменяет конфигурацию.

Реализация: проверки backhaul (handshake, DNS, внешний IP через `awg-backhaul`) — тот же набор команд, что используется в тестах и в прототипе (пункт 0); отдельной логики для `-Check` не создаётся.

`FAIL_CLOSED` проверяется пассивно: правило и счётчики в таблице nftables `seg_failclosed`, состояние `seg-failclosed.service`, привязка selected outbound к `awg-backhaul`. Активная проверка (остановка backhaul) выполняется вручную (пункт 38).

`UNMATCHED_DIRECT` — счётчик страховочного DIRECT. Ненулевое значение означает, что клиент направляет на VPS2 трафик не по `seg-list`; это предупреждение, а не ошибка.

На старом формате `servers.txt` `-Check` работает в режиме совместимости (пункт 4).

Обновить README: раздел о `-Check`, расшифровка полей.

### Пункт 27. Реализовать порядок применения SEG

```text
1. Проверить локальную конфигурацию.
2. Проверить SSH VPS1/VPS2.
3. Выполнить upgrade.
4. Выполнить hardening.
5. Подготовить candidate-конфигурации.
6. Установить fail-closed на VPS2.
7. Настроить маршрутизацию selected-трафика VPS2.
8. Настроить awg-backhaul VPS2.
9. Настроить awg-backhaul/NAT/firewall/DNS VPS1.
10. Проверить handshake.
11. Проверить DNS через backhaul.
12. Проверить egress IP через VPS1.
13. Установить/configure sing-box VPS2.
14. Проверить VLESS/REALITY.
15. Проверить server-side routing (selected → VPS1, прочее по SEG_UNMATCHED_POLICY).
16. Выполнить итоговый -Check.
```

### Пункт 28. Реализовать rollback SEG

Перед применением сохранять:

- backhaul configs;
- nftables rules;
- правила nftables fail-closed;
- sing-box config;
- systemd units.

При ошибке:

- восстановить предыдущую рабочую конфигурацию;
- не ослаблять fail-closed;
- при первой установке оставить sing-box остановленным;
- не переключать `SEG_UNMATCHED_POLICY` и не направлять selected traffic через публичный интерфейс VPS2.

Обновить README: порядок применения, rollback, действия при ошибке.

Реализация: удалённые SEG-скрипты используют шаблон отката из `Invoke-Sync` (копия конфигураций, `trap ERR`, восстановление).

---

## Этап 3. Тестирование

Пункты 32–41 выполняются сначала на прототипе (пункт 0), затем после автоматизации в сокращённом виде. Перекрывающиеся проверки объединяются в один прогон:

- пп. 33 и 38 (маршрутизация selected-трафика и fail-closed);
- пп. 35, 36 и 39 (клиентская маршрутизация, передача домена, DNS).

Проверки backhaul выполняются тем же набором команд, что и `-Check` (пункт 26).

### Пункт 29. Регрессия режима VPN

Режим VPN выполняет прежний код, поэтому регрессия сводится к подтверждению того, что изменения в VPN-скриптах ограничены параметром `-Mode`, диспетчером и новым форматом `servers.txt`.

Минимальный набор:

- `git diff` VPN-скриптов: только `-Mode`, диспетчер и формат `servers.txt`; `bootstrap.sh`, `secure.sh`, `upgrade.sh`, `awg-iptables.service` без изменений;
- `sync-servers.ps1 -Mode VPN -Check` на старом и новом формате: вывод совпадает с эталоном;
- `sync-servers.ps1 -Mode VPN <server>` на READY-сервере: изменений нет;
- `add-client.ps1 -Mode VPN`, `make-client-config.ps1 -Mode VPN`, `remove-client.ps1 -Mode VPN`;
- AWG connectivity с клиента.

Полный чек-лист (provisioning чистого VPS, upgrade, security, изменение VPN-порта, удаление последнего клиента, reboot) выполняется только если VPN-скрипты, кроме перечисленного выше, были изменены:

- `sync-servers.ps1 -Mode VPN all`;
- provisioning чистого VPS;
- повторный sync;
- upgrade;
- security;
- удаление последнего клиента;
- изменение VPN-порта;
- reboot;
- восстановление после reboot.

Эталонный `-Check` до и после изменений должен совпадать.

### Пункт 30. Проверка миграции `servers.txt`

Проверить:

- backup;
- преобразование старого формата;
- повторную миграцию;
- идемпотентность;
- `Role=vpn-server`;
- `-Check` на старом формате: файл не изменён, сообщение «нужна миграция», вывод совпадает с выводом на новом формате;
- пустой `Port` у `seg-exit`;
- исключение SEG-серверов из `-Mode VPN all`.

### Пункт 31. Проверка развёртывания SEG

Использовать:

```text
VPS2 = seg-gateway + sing-box
VPS1 = seg-exit + amnezia
```

Проверить полный deploy из локального source of truth.

### Пункт 32. Проверка backhaul

Проверить:

- отдельные keys;
- отдельный PSK;
- отдельную сеть;
- отдельный порт;
- `awg-backhaul`;
- `Table = off`;
- `AllowedIPs` обеих сторон;
- UDP `SEG_BACKHAUL_PORT` на VPS2 доступен только с IP VPS1;
- входящие сервисные порты VPS1 закрыты;
- `rp_filter` не отбрасывает ответы из backhaul;
- MTU и MSS: передача больших объёмов данных;
- VPS1 инициирует handshake;
- reconnect;
- отсутствие `awg0` на SEG exit;
- NAT VPS1;
- DNS resolver VPS1;
- reboot обоих серверов.

### Пункт 33. Проверка маршрутизации selected-трафика

Проверить:

```text
selected outbound
  → bind_interface = awg-backhaul
  → внешний IP = IP VPS1
```

Проверить:

```text
main default
  → public interface VPS2
```

Остановка `awg-backhaul` не должна выпускать `SEG_MARK`-трафик через публичный интерфейс: помеченный сокет без привязки к `awg-backhaul` дропается правилом fail-closed.

Проверить также:

- `SEG_MARK` не совпадает с fwmark AmneziaWG, метками UFW и `awg-iptables`;
- страховочный DIRECT-трафик не помечается и не использует `awg-backhaul`.

### Пункт 34. Проверка безопасности VPS1

Через backhaul:

```text
SSH → BLOCK
private networks → BLOCK
loopback → BLOCK
metadata → BLOCK
DNS resolver → ALLOW только от VPS2
Internet forwarding → ALLOW
```

### Пункт 35. Проверка клиентской маршрутизации

Для selected resource:

```text
Client → VPS2 → VPS1 → Internet
external IP = VPS1
```

Для ресурса вне `seg-list`:

```text
Client → Internet напрямую
external IP = ISP клиента
VPS2 не участвует
```

Проверить:

- IPv4 и IPv6;
- SSH к VPS при включённом TUN-клиенте идёт DIRECT.

### Пункт 36. Проверка передачи домена

Для selected domain проверить:

```text
client классифицирует domain
VLESS передаёт destination domain
VPS2 получает domain
VPS2 повторно сопоставляет domain с seg-list
```

Проверить отдельно прямые IP/CIDR-подключения.

Проверить sniffing: ресурс из `seg-list`, переданный клиентом как IP без домена, определяется по SNI/QUIC и уходит на VPS1. Отдельно проверить ECH: домен недоступен, ресурс должен покрываться CIDR.

### Пункт 37. Проверка server-side routing и страховочного DIRECT

Принудительно отправить на VPS2:

```text
destination ∈ seg-list
  → VPS1

destination ∉ seg-list (SEG_UNMATCHED_POLICY=direct)
  → DIRECT через VPS2, external IP = VPS2

destination ∉ seg-list (SEG_UNMATCHED_POLICY=block)
  → BLOCK
```

Проверить:

- клиент с полностью проксирующим (неверным) профилем: selected-ресурсы выходят с IP VPS1, остальные с IP VPS2;
- `UNMATCHED_DIRECT` в `-Check` растёт при таком трафике и не растёт при корректном профиле;
- до проверки `seg-list` блокируются loopback, private, link-local, metadata, backhaul network и локальные сети VPS2 при обеих политиках;
- исходящий tcp/25 заблокирован;
- direct-трафик не использует `awg-backhaul`;
- после `remove-client` и `sync` удалённый UUID не принимается.

### Пункт 38. Проверка fail-closed

Для selected resource:

```text
backhaul UP
  → external IP = VPS1

backhaul DOWN
  → connection FAIL

backhaul DOWN
  → external IP VPS2 не используется
```

Проверить:

- удаление маршрута;
- остановку интерфейса;
- остановку VPS1;
- reboot;
- `ufw reload`.

### Пункт 39. Проверка DNS

Проверить:

- selected DNS через VPS1;
- DIRECT DNS локально;
- разрешённый DNS service path к VPS1;
- блокировку остальной backhaul network;
- FakeIP;
- reverse mapping;
- IPv4;
- отсутствие selected DNS leak;
- блокировку selected AAAA при отсутствии IPv6 egress;
- отсутствие fallback selected-домена на локальный резолвер VPS2 при недоступном DNS VPS1;
- прямые IP/CIDR подключения.

### Пункт 40. Проверка версии `seg-list`

Проверить:

- изменение `version`;
- изменение SHA-256;
- обнаружение устаревшего generated profile;
- обновление профиля;
- рассинхронизацию client/server list: selected-ресурс из нового серверного списка при устаревшем клиентском профиле выходит через VPS1, а не с IP VPS2.

### Пункт 41. Проверка отказов и восстановления

Проверить:

- VPS1 недоступен;
- VPS2 недоступен;
- backhaul down;
- sing-box down;
- DNS VPS1 down;
- правила fail-closed отсутствуют (таблица `seg_failclosed` не загружена);
- reboot VPS1;
- reboot VPS2;
- изменение IP VPS1;
- изменение IP VPS2;
- изменение `seg-list.json`;
- частичное применение;
- rollback;
- повторный sync.

### Пункт 42. Финальная проверка

Проверить:

- firewall;
- nftables fail-closed;
- маршрутизация selected-трафика;
- SSH hardening;
- права файлов;
- backup/restore по режимам (`server.env` и `seg.env` независимо);
- хранение секретов;
- отсутствие секретов в логах;
- идемпотентный sync;
- `-Check`;
- обновление SEG;
- обновление клиентских профилей;
- README;
- CLAUDE.md.

### Пункт 43. Финальная сверка README и SEG.md

Критерий приёмки: `README.md` покрывает всё, что описано в `SEG.md`.

Пройти разделы `SEG.md` и убедиться, что README содержит эквивалент:

| `SEG.md` | README |
|---|---|
| 1–3 назначение, схема, режимы | модель, сравнение VPN и SEG |
| 4–5 `servers.txt`, миграция, порты, фаервол по ролям | `servers.txt`, роли, новый VPS |
| 6 `seg.env`, backup | локальные данные, `generate-server-env.ps1 -Mode` |
| 7 `seg-list.json` | структура, порядок изменения |
| 8–10, 21 клиент, DNS, версия списка | клиент, профили, DNS-модель |
| 11–14 VPS2, страховочный DIRECT, маршрутизация selected-трафика, fail-closed | роль `seg-gateway`, `SEG_UNMATCHED_POLICY`, `ufw reload` |
| 15–18 VPS1, backhaul, безопасность | роль `seg-exit`, backhaul |
| 19–20 REALITY, UUID | ключи, клиенты, отзыв |
| 22 IPv6 | ограничения и включение |
| 23 `-Check` | расшифровка полей, `UNMATCHED_DIRECT` |
| 24 порядок развёртывания | порядок, rollback |
| 25 риски | риски и ограничения |
| 27 структура реализации | расположение скриптов и шаблонов SEG |

Дополнительно проверить, что в README обновлены:

- требования (локальный `sing-box 1.14.4`, клиент);
- примеры запуска со всеми `-Mode`;
- сценарии эксплуатации: замена VPS, смена IP, ротация ключей и UUID, компрометация VPS1/VPS2/ноутбука, восстановление на другом ноутбуке;
- `CLAUDE.md` и инструкции по запуску скриптов.

При расхождении между `README.md` и `SEG.md` пункт не считается выполненным.