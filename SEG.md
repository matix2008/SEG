# SEG — Selective Egress Gateway

## 1. Назначение

SEG — схема выборочной маршрутизации клиентского трафика через российский gateway и зарубежный exit.

Основное правило:

```text
destination ∈ seg-list
  → VPS2 → VPS1 → Internet

destination ∉ seg-list
  → DIRECT с клиента
```

Дополнительный (страховочный) механизм на VPS2: если клиент по ошибке направил на VPS2 трафик не по `seg-list`, VPS2 применяет `seg-list` сам.

```text
destination ∈ seg-list  → awg-backhaul → VPS1  (всегда, независимо от клиента)
destination ∉ seg-list  → DIRECT через VPS2    (страховка, SEG_UNMATCHED_POLICY=direct)
```

Страховка не заменяет клиентскую маршрутизацию: через VPS2 трафик выходит с IP VPS2, а наличие такого трафика считается признаком неверной настройки клиента (см. раздел 12 и `-Check`).

## 2. Общая схема

```text
Client
  │
  ├── destination ∉ seg-list
  │       └────────────────────────────► Internet напрямую
  │
  └── destination ∈ seg-list
          │
          │ VLESS + REALITY / TCP 443
          ▼
       VPS2 RU
          │
          ├── seg-list (серверная проверка)
          │       │
          │       │ AmneziaWG backhaul
          │       ▼
          │    VPS1
          │       └────────────────────► Internet
          │                              source IP = VPS1
          │
          └── не seg-list (страховка)
                  └────────────────────► Internet
                                         source IP = VPS2
```

## 3. Режимы проекта

Проект поддерживает:

```text
VPN
SEG
```

### VPN

```text
Client → vpn-server → Internet
```

### SEG

```text
Client → seg-gateway → seg-exit → Internet
```

Первая реализация:

```text
seg-gateway:
  sing-box (VLESS/REALITY) + приёмная сторона backhaul типа amnezia

seg-exit:
  клиент backhaul типа amnezia
```

## 4. Модель серверов

Формат `servers.txt`:

```text
Name;IP;Port;Role;Type;Enabled
```

Роли:

```text
vpn-server     сервер режима VPN
seg-gateway    входная точка режима SEG
seg-exit       точка выхода режима SEG
```

Роль определяет, каким режимом управляется хост: один хост принадлежит ровно одному режиму. Режим VPN обрабатывает только `vpn-server` и игнорирует остальные роли, режим SEG обрабатывает только `seg-gateway` и `seg-exit` и игнорирует `vpn-server`. Так рабочие VPN-серверы и SEG-узлы могут лежать в одном `servers.txt`, а `secure.sh` режима VPN не закрывает порт VLESS gateway.

`Type` показывает, какой VPN-протокол используется на сервере:

```text
vpn-server    одно значение: протокол VPN-сервиса для клиентов.
seg-gateway   одно или несколько значений через запятую: типы приёмной
              стороны backhaul, установленные на gateway.
seg-exit      одно значение: тип клиента backhaul; должно входить
              в список Type seg-gateway.
```

Значения `Type`: `amnezia`, позже `openvpn` и другие. `sing-box` в `Type` не допускается: он подразумевается ролью `seg-gateway`. Допускаются только типы, реализованные в соответствующем режиме (сейчас везде только `amnezia`). Разделитель списка — запятая без пробелов, так как `;` разделяет поля.

Пример:

```text
vpn-01;151.236.30.153;42157;vpn-server;amnezia;true
seg-ru;1.2.3.4;443;seg-gateway;amnezia;true
seg-eu;5.6.7.8;;seg-exit;amnezia;true
```

### VPN

Режим VPN использует только:

```text
Role = vpn-server
```

`all` означает все enabled `vpn-server`. Тип определяет, какой VPN устанавливается на сервер.

### SEG

Первая версия требует:

```text
1 enabled seg-gateway
1 enabled seg-exit
```

`all` означает всю SEG-пару.

`vpn-server` в SEG не используется.

Формат допускает несколько `seg-exit` и несколько типов backhaul у gateway, но первая версия ограничена одним gateway и одним exit с типом `amnezia`. Несколько exit потребуют правил выбора exit в `seg-list`, раздельных адресов backhaul (сеть `/30` рассчитана на одного peer) и отдельных ключей на каждый exit; формат `servers.txt` при этом не меняется.

### Совместимость со старым форматом

Старый формат:

```text
Name;IP;Port;Enabled
```

мигрируется в новый (`Role = vpn-server`, `Type = amnezia`) только обычным запуском `sync-servers.ps1` после резервной копии и проверки.

`-Check` ничего не записывает: старый формат он читает в режиме совместимости (как `vpn-server` + `amnezia`) и сообщает «нужна миграция». Вывод `-Check` на старом и новом формате для режима VPN должен совпадать.

Пустой `Port` допустим только для `seg-exit` (для него он обязан быть пустым) и не участвует в проверке уникальности. Уникальной должна быть пара `IP:Port` среди строк, у которых `Port` задан.

### Проверки валидатора

- допустимые роли и типы для роли (см. выше); непустой `Type` обязателен для всех ролей;
- `seg-exit.Type` входит в список `seg-gateway.Type`;
- для каждого типа из списка gateway в `seg.env` задан порт backhaul (для `amnezia` — `SEG_BACKHAUL_PORT`);
- в режиме SEG ровно один enabled `seg-gateway` и один enabled `seg-exit`.

## 5. Порты

`servers.txt.Port` означает публичный сервисный порт роли.

```text
vpn-server
  → публичный порт VPN-сервиса (для amnezia — UDP).

seg-gateway
  → TCP-порт VLESS/REALITY.

seg-exit
  → пусто.
```

Порт приёмной стороны backhaul хранится не в `servers.txt`, а в `seg.env`:

```text
SEG_BACKHAUL_PORT     порт для типа amnezia (единственный тип первой версии)
```

В одной ячейке `Port` уместно только одно значение, а типов backhaul у gateway может быть несколько. При добавлении второго типа порт задаётся отдельным параметром на тип (например `SEG_BACKHAUL_PORT_OPENVPN`), параметры AmneziaWG остаются у типа `amnezia`.

Фаервол по ролям (`secure.sh`):

```text
seg-gateway
  → SSH;
  → TCP Port (VLESS/REALITY);
  → UDP SEG_BACKHAUL_PORT только от публичного IP seg-exit.

seg-exit
  → SSH;
  → входящие UDP/TCP сервисные порты не открываются
    (backhaul инициируется самим VPS1).
```

Смена публичного IP `seg-exit` требует повторного `sync` (правило источника на VPS2).

## 6. Конфигурация

SEG использует отдельный файл:

```text
config/seg.env
```

Файл `config/server.env` режимом SEG не читается и не изменяется. Параметры SEG имеют префикс:

```text
SEG_
```

Backup и restore выполняются по файлам независимо:

```text
config/server.env.<время>.bak    → VPN
config/seg.env.<время>.bak       → SEG
```

Копии `seg.env` содержат приватные ключи REALITY и backhaul, не шифруются и хранятся (последние три) так же, как копии `server.env`.

Backhaul использует отдельные:

- private/public keys VPS1;
- private/public keys VPS2;
- PSK;
- сеть;
- адреса;
- UDP-порт;
- AWG-параметры;
- интерфейс.

Интерфейс:

```text
awg-backhaul
```

Backup/restore выполняется отдельно для параметров VPN и SEG.

Образец формата — `config/seg.env.example` (секреты пусты, параметры AmneziaWG — нули; рабочий файл создаёт `generate-server-env.ps1 -Mode SEG`). Формат строк `NAME=VALUE`, комментарии `#`; неизвестные и повторяющиеся параметры отвергаются (опечатки не пропускаются).

Валидатор (`scripts\lib\segenv.ps1`) проверяет все параметры и сообщает обо всех проблемах сразу, не выводя значения секретов:

- REALITY: ключи (43 символа base64url, не равны друг другу), `short_id` (2–16 hex-символов строчными, чётное число), `server_name`, `dest` (`host:port`), `flow`, `fingerprint`;
- backhaul: ключи и PSK (44 символа base64, все различны), сеть `/30` (адрес сети, без пересечения с зарезервированными, например с сетью клиентов VPN), адреса VPS1 и VPS2 внутри сети и различны, порт, имя интерфейса (не `awg0`);
- AmneziaWG: `Jc`, `Jmin ≤ Jmax`, `S1–S4` (15–150), `H1–H4` (уникальны), `RandomTrailers`, `MTU` не выше предела без фрагментации (раздел 13): `1500 − 28 − 32 − S4`, при `RandomTrailers = on` ещё минус 480 (при `S4 = 144`: 1296 и 816);
- метки `SEG_MARK` и `SEG_UNMATCHED_MARK`: hex не меньше `0x1000`, различны, не равны `0xca6c` (fwmark AmneziaWG по умолчанию);
- `SEG_UNMATCHED_POLICY`: `direct` или `block`.

Параметры хранятся по ролям пары: `*_VPS1` — `seg-exit`, `*_VPS2` — `seg-gateway`. Порт VLESS в `seg.env` не хранится (это `Port` у `seg-gateway` в `servers.txt`), UUID клиентов — в `clients/seg/`.

Генерация (`generate-server-env.ps1 -Mode SEG`, реализация — `scripts\seg\generate-server-env.ps1`):

- секреты создаются заново при каждой генерации: пара REALITY (локальный `sing-box 1.14.4`, `tools\sing-box.exe`) и `short_id` (8 случайных байт), две пары ключей и PSK backhaul (`awg`);
- параметры AmneziaWG: `Jc` 4–12, `Jmin` 20–60, `Jmax` от `Jmin + 20` до 120, `S1 = S2 = S3 = S4` в диапазоне 15–150, `H1–H4` уникальные значения от 5;
- `SEG_BACKHAUL_MTU` не задаётся вручную: он равен пределу без фрагментации (формула выше) минус 16 байт запаса, в пределах 576–1420 (при `S4 = 144`, `RandomTrailers = on` — 800);
- нечувствительные настройки существующего файла (имя и dest REALITY, flow, fingerprint, сеть, адреса, порт и интерфейс backhaul, `RandomTrailers`, метки, политика) сохраняются; если файл нечитаем, берутся значения по умолчанию (`www.microsoft.com`, `10.77.0.0/30`, порт 42100, `awg-backhaul`, `RandomTrailers = on`, метки `0x5e90` и `0x5e91`, политика `direct`);
- результат проверяется валидатором до замены файла; при ошибке `seg.env` не меняется, резервная копия создаётся только после успешной проверки;
- проверка наличия `sing-box` нужной версии и `awg.exe` выполняется до подтверждения и до любых изменений;
- сеть клиентов VPN из `config/server.env` (если файл есть) добавляется в зарезервированные сети для проверки пересечения.

## 7. `seg-list.json`

Файл:

```text
config/seg-list.json
```

является единственным источником selective routing rules. В файле нет секретов, он хранится в git.

Структура:

```json
{
  "version": 1,
  "groups": [
    {
      "name": "github",
      "title": "GitHub",
      "enabled": true,
      "domains": [],
      "domain_suffixes": ["github.com"],
      "cidrs": [],
      "sources": ["https://api.github.com/meta, checked 2026-11-09"]
    }
  ]
}
```

- `version` — целое число не меньше 1; повышается вручную при изменении списка (для людей и отчётов; устаревание профилей определяет SHA-256, раздел 21);
- `groups` — непустой массив групп; у группы `name` (строчный идентификатор, уникален), `title`, `enabled` (по умолчанию `true`) и четыре списка: `domains` (точное имя), `domain_suffixes` (имя и все поддомены), `cidrs` (IPv4 CIDR), `sources` (откуда взят список, текст);
- отключённая группа (`enabled: false`) в правила не попадает;
- неизвестные поля отвергаются, чтобы опечатки не пропускались.

Проверки (`scripts\lib\seglist.ps1`, сообщает обо всех проблемах сразу):

- имена в нижнем регистре, без точки в начале и подстановок (`*.`), не IP-адрес, длина до 253;
- CIDR только IPv4 с префиксом от 8, адрес сети без «хвоста», не пересекается с частными и зарезервированными диапазонами (`10/8`, `172.16/12`, `192.168/16`, `127/8`, `169.254/16`, `100.64/10`, `198.18/15`, multicast): они блокируются на VPS1 и VPS2, а `198.18.0.0/15` занят FakeIP клиента;
- у включённой группы есть хотя бы одна запись, а у включённых групп вместе — хотя бы один домен или суффикс (DNS-правила строятся по доменам);
- одинаковые записи в разных группах объединяются (первое вхождение сохраняет порядок), внутри группы дубли запрещены.

Первая версия содержит:

```text
GitHub
GitHub Copilot
ChatGPT / OpenAI
Facebook / Messenger
Telegram
YouTube
```

Состав группы YouTube подтверждён прототипом: `youtube.com`, `youtu.be`, `youtube-nocookie.com`, `ytimg.com`, `ggpht.com`, `googlevideo.com`, `youtubei.googleapis.com`, `jnn-pa.googleapis.com`. Без `googlevideo.com`, `ytimg.com`, `ggpht.com` и `jnn-pa.googleapis.com` видео не воспроизводится.

Состав групп получен так: GitHub и GitHub Copilot — из публичного `https://api.github.com/meta` (`domains.website`, `domains.packages`, `domains.copilot`) и документации GitHub; Telegram (IPv4 CIDR) — из `https://core.telegram.org/resources/cidr.txt`; YouTube и ChatGPT — по прототипу; Facebook / Messenger — начальный список, на прототипе не проверялся. Источник каждой группы записан в её `sources`. IPv6-диапазоны Telegram не включены (selected-трафик пока только IPv4, раздел 22).

Для файла вычисляется SHA-256 по содержимому с нормализацией: удаляется BOM, переводы строк приводятся к LF, поэтому значение не зависит от того, как git выгрузил файл (CRLF или LF).

Из файла генерируются два inline `rule_set` для `sing-box`: `seg-domains` (правила `domain` и `domain_suffix`, пустые не создаются) и `seg-cidrs` (правило `ip_cidr`, только если есть CIDR). Домены и IP-диапазоны разделены, потому что IP-правила не должны попадать в DNS-правила. Наборы подставляются в шаблоны клиента и VPS2 как JSON-фрагменты (`SEG_RULE_SETS_JSON`, `SEG_DOMAIN_RULE_SETS_JSON`, `SEG_ROUTE_RULE_SETS_JSON`, `SEG_POST_RESOLVE_RULES_JSON`).

Правила используются:

- на клиенте;
- на VPS2.

## 8. Клиент

Эталон:

```text
sing-box 1.14.4
```

Клиент работает в TUN-режиме.

Правило:

```text
destination ∈ seg-list
  → VLESS/REALITY → VPS2

destination ∉ seg-list
  → DIRECT
```

Клиент не знает VPS1.

Профиль клиента:

- содержит `route.auto_detect_interface`, чтобы соединение с VPS2 не попадало в собственный TUN;
- не перехватывает управляющий трафик (SSH к VPS): адреса VPS отсутствуют в `seg-list` и идут DIRECT.

Windows-клиент (проверено прототипом):

- TUN-адаптер с `auto_route` и `strict_route`. `strict_route` блокирует порт 53 на всех интерфейсах, кроме TUN, в том числе для самого `sing-box`: прямой DNS нельзя задавать как UDP/TCP 53, запросы зависают без ошибки в журнале. Для прямого DNS используется DoH/DoT;
- `seg-list` задаётся двумя inline `rule_set`: `seg-domains` (используется в DNS-правилах, в правиле QUIC и в маршрутизации) и `seg-cidrs` (только маршрутизация, раздел 7);
- порядок правил маршрутизации: `sniff`, `hijack-dns`, `ip_is_private → direct`, QUIC (UDP/443) к `seg-domains` → reject, `seg-domains` и `seg-cidrs` → VLESS, `final` → direct;
- QUIC к selected-доменам отклоняется, чтобы браузер переходил на TCP (UDP через VLESS не проверялся);
- full-tunnel клиент AmneziaWG (kill-switch) с TUN-режимом несовместим: на время работы SEG-клиента он отключается.

SEG-клиенты (реестр; сам профиль клиента — в `clients/generated/seg`):

```text
clients/seg/<client>.json
```

Запись клиента:

```json
{
  "name": "laptop",
  "uuid": "3f2b8c1e-0d4a-4b7e-9c1a-5e6f7a8b9c0d",
  "enabled": true,
  "created": "2026-11-09T14:30:00.0000000+03:00"
}
```

- имя клиента: 1–64 символа (латинские буквы, цифры, `.`, `_`, `-`), первый символ — буква или цифра, без точки в конце. Имя совпадает с именем файла (без учёта регистра) и является именем пользователя в `sing-box`. Запрещены имена, оканчивающиеся на `.meta` (совпали бы с файлом метаданных другого клиента), и зарезервированные имена устройств Windows (`con`, `nul`, `com1` и т. п.);
- `uuid` — случайный UUID v4 строчными буквами, у каждого клиента свой (повтор запрещён), нулевой UUID недопустим; генерируется локально при создании клиента;
- `enabled: false` отключает клиента: его UUID не попадает в конфигурацию VPS2 при следующем `sync`, профиль и запись остаются;
- `created` — дата создания в формате ISO 8601 со смещением.
- неизвестные и отсутствующие поля отвергаются; UUID в сообщения об ошибках не попадает.

UUID — единственный секрет клиента: тот, кто его знает, может пользоваться VPS2 (раздел 25). Поэтому весь каталог `clients/` в `.gitignore`, его нужно хранить в зашифрованном виде вместе с остальными секретами и передавать клиенту только вместе с профилем по защищённому каналу.

Generated profiles:

```text
clients/generated/seg/<client>.json
clients/generated/seg/<client>.meta.json
```

`meta.json` содержит:

```text
segListVersion       версия seg-list.json, с которой собран профиль
segListSha256        SHA-256 seg-list.json (раздел 7)
serverConfigSha256   SHA-256 параметров подключения к серверу
generatedAt          дата и время сборки (ISO 8601 со смещением)
```

`serverConfigSha256` считается не по всему серверному конфигу, а по параметрам, от которых зависит подключение клиента: адрес и TCP-порт VPS2, `server_name`, публичный ключ и `short_id` REALITY, `flow`, `fingerprint`. Список пользователей в хэш не входит: добавление и удаление клиентов не делает профили остальных клиентов устаревшими, а смена ключей REALITY или адреса — делает.

Пользователи `sing-box` на VPS2 формируются из `clients/seg/*.json` (только `enabled`, по имени). Пустой список допустим: `sing-box` запускается, но подключиться никто не может. VPN-клиент с именем `seg` создать нельзя: каталог `clients/generated/seg` принадлежит режиму SEG. Файлы SEG имеют расширение `.json`, а VPN-код при синхронизации затрагивает только `*.conf`, поэтому режимы не мешают друг другу.

## 9. Передача destination

Для selected domain:

```text
domain
  → client routing
  → VLESS destination = domain
  → VPS2
  → server-side domain rule
```

Selected domain не должен преобразовываться клиентом в destination IP до формирования VLESS-запроса.

Для прямых IP-подключений используются CIDR-правила.

Если клиент всё же передал ресурс из `seg-list` как IP или без домена, на VPS2 включён sniffing (TLS SNI, QUIC): домен восстанавливается из соединения и повторно сопоставляется с `seg-list` по домену и CIDR. Подтверждено прототипом: запрос на IP-адрес сайта с SNI из `seg-list` уходит через VPS1. Ограничение: при ECH (Encrypted Client Hello) SNI скрыт, домен восстановить нельзя, остаётся только сопоставление по CIDR; поведение при ECH проверяется отдельно (roadmap, пункт 36).

## 10. DNS клиента

Клиент использует FakeIP/reverse mapping.

FakeIP применяется только к доменам `seg-list`. Остальные домены резолвятся локально (DIRECT DNS) и не получают FakeIP-адресов.

Selected DNS:

```text
Client
  → VLESS/REALITY
  → VPS2
  → awg-backhaul
  → DNS resolver VPS1
```

DIRECT DNS:

```text
Client
  → прямой DoH/DoT-резолвер (не порт 53: при strict_route на Windows он блокируется)
```

Для selected traffic:

```text
DNS strategy = ipv4_only
```

если IPv6 egress VPS1 не подтверждён.

Приложенческий DoH/DoT должен быть отключён или перехвачен TUN.

Подтверждено прототипом: FakeIP (`198.18.0.0/15`) получают только домены `seg-list`, остальные домены резолвятся прямым DNS и получают настоящие адреса. Прямой DNS на Windows при `strict_route` — только DoH/DoT (раздел 8). Обратные (PTR) запросы Windows к адресу TUN-DNS остаются без ответа, поэтому `nslookup` показывает `UnKnown` и ждёт около 2 секунд; на работу это не влияет.

## 11. VPS2 — `seg-gateway`

VPS2 использует:

```text
sing-box 1.14.4
AmneziaWG
nftables
iproute2
```

Пакет `sing-box` скачивается на ноутбук (`tools\sing-box-1.14.4-linux-amd64.tar.gz`), проверяется по SHA-256 из `seg\sing-box.sha256` (значения совпадают с хэшами официального релиза v1.14.4) и копируется на VPS2; на VPS2 хэш проверяется ещё раз после копирования, загрузка с GitHub на VPS2 не используется. Локальный `tools\sing-box.exe` (клиент и локальные проверки) тоже сверяется с этим файлом. Версия сервера и эталонного клиента одна — 1.14.4; Hiddify в критерии приёмки первой версии не входит. Конфигурации проверяются командой `sing-box check` до отправки. Серверный конфиг содержит `routing_mark`, который поддерживается только на Linux: Windows-бинарник `sing-box check` его отклоняет. Поэтому серверный конфиг проверяется Linux-бинарником (на VPS2 до замены рабочего конфига или в WSL), клиентский — локальным Windows-бинарником.

Служба `sing-box` на VPS2 работает от отдельного пользователя `sing-box` с `CAP_NET_ADMIN` (нужна для `routing_mark`) и `CAP_NET_BIND_SERVICE`, `ProtectSystem=strict`. В прототипе процесс занимает около 55 МБ RSS при VPS2 с ~0,9 ГБ RAM без swap.

Функции:

- принимает VLESS + REALITY;
- аутентифицирует клиента;
- определяет destination: домен из VLESS-запроса либо домен, восстановленный sniffing (TLS SNI, QUIC);
- проверяет destination по `seg-list`;
- selected traffic отправляет через `awg-backhaul`;
- unmatched proxy traffic обрабатывает по `SEG_UNMATCHED_POLICY`;
- поддерживает fail-closed для selected traffic.

VPS2 не является штатным Internet egress: прямой выход используется только как страховка для трафика вне `seg-list` (раздел 12).

## 12. Server-side routing и страховочный выход

Правило VPS2:

```text
destination ∈ seg-list
  → awg-backhaul → VPS1

destination ∉ seg-list
  → SEG_UNMATCHED_POLICY:
      direct → DIRECT через VPS2   (по умолчанию)
      block  → BLOCK
```

Принадлежность к `seg-list` проверяется по домену, по sniffed-домену и по CIDR. Sniffing включён на входящем соединении VPS2: это нужно, чтобы выбранный ресурс, который клиент ошибочно передал как IP, всё равно попал в `awg-backhaul`, а не ушёл с IP VPS2.

До проверки `seg-list` блокируются (при любой политике):

- loopback;
- private networks;
- link-local;
- metadata addresses;
- backhaul network;
- локальные сети VPS2.

Служебное исключение:

```text
VPS2_BACKHAUL_IP
  → VPS1_BACKHAUL_IP:DNS
  → ALLOW
```

Остальной доступ к backhaul network запрещён.

### Порядок правил sing-box на VPS2

Подтверждено прототипом:

1. `sniff` (TLS SNI, QUIC);
2. reject для private, loopback и link-local адресов (`ip_is_private`; сеть backhaul входит в private);
3. набор правил `seg-domains` и `seg-cidrs` (домен, sniffed-домен, CIDR) → selected outbound;
4. `resolve` локальным резолвером VPS2 и повторный reject private: домен, указывающий на локальный адрес, не должен пройти;
5. набор `seg-cidrs` ещё раз, уже по разрешённому адресу: домен вне `seg-list`, резолвящийся в адрес из его CIDR (например, другой домен на IP Telegram), тоже идёт selected;
6. `final` → direct (политика `direct`) или reject (политика `block`).

`seg-list` на VPS2 и на клиенте задаётся двумя inline `rule_set`: `seg-domains` (домены и суффиксы) и `seg-cidrs` (IP-диапазоны, если они есть). IP-правила не входят в набор для DNS-правил: DNS-правило использует только `seg-domains`.

Selected outbound использует `domain_resolver` на DNS VPS1 с `detour` через selected outbound. DNS-правило отправляет домены `seg-list` на resolver VPS1, остальные — на локальный.

Проверено: домен из VLESS-запроса, sniffed-домен при IP-подключении с SNI из `seg-list` и CIDR дают выход через VPS1, остальной трафик выходит с IP VPS2. Конфигурация VPS2, сгенерированная из `seg-list.json` (шаблон и `rule_set`), проверена на VPS2: суффиксы YouTube, ChatGPT, GitHub, Facebook, Telegram выходят с IP VPS1; Telegram по IP (`149.154.167.99`) и домен вне списка, резолвящийся в этот диапазон (`149.154.167.99.nip.io`), идут через `seg-out`; адрес вне списка (`8.8.4.4`) идёт direct; при остановленном DNS VPS1 не резолвившиеся ранее selected-домены не открываются и не уходят с IP VPS2.

### Страховочный DIRECT

- Direct-трафик не получает `SEG_MARK` и никогда не использует `awg-backhaul`.
- Блокируется исходящий tcp/25.
- Ведутся счётчики unmatched-соединений без содержимого трафика и имён.
- Счётчик отображается в `-Check` как `UNMATCHED_DIRECT`: ненулевое значение означает, что клиент направляет на VPS2 трафик не по `seg-list`.
- Отзыв UUID выполняется через `remove-client` и `sync`.

Реализация счётчика (проверена на прототипе): direct outbound получает отдельную метку `routing_mark = 0x5e91` (не `SEG_MARK`, в `awg-backhaul` не попадает), а в цепочке `output` таблицы `seg_failclosed` стоит правило `meta mark 0x5e91 ct state new counter name "unmatched_direct"`. Значение читается командой `nft list counter inet seg_failclosed unmatched_direct`. Selected-трафик и REALITY-handshake счётчик не увеличивают: три прямых соединения дали `packets 3`, selected — 0. Счётчик обнуляется при перезагрузке таблицы и VPS2.

Проверено: через VLESS заблокированы `127.0.0.1`, `169.254.169.254`, адреса backhaul (`10.77.0.1`, `10.77.0.2`), `10.0.0.0/8` и `192.168.0.0/16`, а также домены, резолвящиеся в такие адреса (`localtest.me` в `127.0.0.1`, `10.77.0.2.nip.io` в `10.77.0.2`): `sing-box` отклоняет соединение до исходящего подключения, в журнале нет ни одного outbound к этим адресам. Блокировка tcp/25 вне backhaul подтверждена ростом счётчика правила.

### DNS на VPS2

```text
домен ∈ seg-list
  → DNS resolver VPS1 через awg-backhaul
     (без fallback на локальный резолвер)

домен ∉ seg-list
  → локальный резолвер VPS2
```

У selected outbound `domain_resolver` указывает только на resolver VPS1. При недоступности resolver VPS1 selected-запрос завершается ошибкой.

Проверено на прототипе: при остановленном `unbound` на VPS1 selected-домен (`chatgpt.com`) не открывается (в журнале VPS2 ошибка `lookup chatgpt.com: read udp 10.77.0.1:…->10.77.0.2:53`), IP VPS2 для него не используется, домены вне `seg-list` продолжают работать через локальный резолвер VPS2. После запуска `unbound` selected-трафик восстанавливается без перезапуска `sing-box`.

## 13. Маршрутизация selected-трафика VPS2

Прототип (этап 0) показал, что отдельная таблица `seg` и `ip rule` по `SEG_MARK` не нужны. Сокет, привязанный `bind_interface = awg-backhaul`, выходит в туннель без маршрутов в таблицах и не использует main table. При падении интерфейса `connect` завершается ошибкой, а трафик вне `seg-list` не затрагивается. Маршрут через `awg-backhaul` с высокой метрикой также не нужен.

Backhaul использует:

```text
Table = off
```

Selected outbound получает:

```text
bind_interface = awg-backhaul
routing_mark = SEG_MARK
```

`SEG_MARK` не совпадает с fwmark AmneziaWG, метками UFW и `awg-iptables`. В прототипе `SEG_MARK = 0x5e90`. Метка нужна только правилу fail-closed (раздел 14).

Основная таблица VPS2 не изменяется:

```text
main default
  → public interface VPS2
```

Selected traffic не использует main table. Привязка `bind_interface` и правило nftables с меткой — два независимых уровня: привязка направляет трафик в backhaul, правило из раздела 14 не выпускает его в публичный интерфейс.

Ответный трафик из backhaul приходит с внешними адресами не со стороны публичного интерфейса, поэтому `rp_filter` на VPS2 не должен отбрасывать его (loose или отключённый для `awg-backhaul`). На образе Ubuntu 24.04 `rp_filter = 2` (loose) для `all`, `default`, `eth0` и `awg-backhaul` уже задан в `/etc/sysctl.d/10-network-security.conf`, и ответы проходят. Автоматизация должна проверять значение и не ставить `1` (strict).

MTU `awg-backhaul` задаётся явно (`SEG_BACKHAUL_MTU`), MSS clamp не нужен. Прототип показал:

- внешний UDP-пакет AmneziaWG больше внутреннего на 20 (IPv4) + 8 (UDP) + 32 (заголовок) + `S4` (паддинг данных) + случайный хвост при `RandomTrailers = on`. По захвату на внешнем интерфейсе хвост достигает ~480 байт. Условие отсутствия фрагментации: `MTU ≤ 1500 − 28 − 32 − S4 − 480` (при `S4 = 144` это ≈ 816);
- при MTU 1420 (по умолчанию) фрагментируются 100% пакетов большой передачи (IP-фрагменты на VPS1, повторная сборка на VPS2); при 1300, 1000 и 900 с `RandomTrailers = on` дробится 24–100% пакетов; при `RandomTrailers = off` фрагментов нет при MTU ≤ 1296;
- принято: `RandomTrailers = on` (обфускация) и `SEG_BACKHAUL_MTU = 800` на обеих сторонах. При 800, 820, 840, 860, 880 и 700–400 счётчики `IpFragCreates` и `IpReasmOKs` не растут, повторные передачи по 50 МБ после перезапуска — без фрагментов;
- следствие малого MTU: внутри backhaul нельзя передавать IPv6 (минимальный MTU IPv6 — 1280); для SEG IPv6 (раздел 22) придётся выбирать другое сочетание `S4`, хвоста и MTU;
- `MSS` TCP вычисляется из MTU интерфейса, к которому привязан сокет: при `bind_interface = awg-backhaul` MSS согласуется с MTU backhaul, `MSS clamp` на VPS1 для транзитного трафика не потребовался;
- MTU пути между VPS (1500) проверен пингом с DF; значение `SEG_BACKHAUL_MTU` нужно пересчитывать при изменении `S4` и при IPv6 внешнего транспорта (накладные расходы на 20 байт больше).

Пропускная способность одного потока через backhaul при MTU 800 в прототипе около 3–10 МБ/с (RTT VPS1–VPS2 около 155 мс).

## 14. Fail-closed VPS2

Selected outbound sing-box использует:

```text
bind_interface = awg-backhaul
routing_mark = SEG_MARK
```

nftables:

```text
mark = SEG_MARK
AND oifname != awg-backhaul
  → DROP
```

Fail-closed:

- загружается раньше sing-box;
- не зависит от UFW;
- сохраняется после reboot;
- не удаляется `ufw reload`.

При отсутствии backhaul:

```text
selected traffic → FAIL
```

Запрещено:

```text
selected traffic → public interface VPS2
```

Страховочный DIRECT (раздел 12) этому правилу не противоречит: он относится только к трафику вне `seg-list` и не помечается.

Реализация в прототипе:

- таблица `inet seg_failclosed`, цепочка `output` (hook output, приоритет `-100`): `meta mark SEG_MARK` и `oifname != "awg-backhaul"` → drop со счётчиком; в ту же цепочку входит блокировка исходящего tcp/25 не через backhaul;
- таблица загружается из `/etc/seg/seg-failclosed.nft` юнитом `seg-failclosed.service` (oneshot, `Before=network-pre.target sing-box.service awg-quick@awg-backhaul.service`); `sing-box.service` имеет `Requires=` на fail-closed и только `Wants=` на `awg-quick@awg-backhaul`, жёсткой зависимости от backhaul нет;
- после перезагрузки порядок запуска: fail-closed, backhaul, sing-box.

Проверено: помеченный сокет без привязки к `awg-backhaul` дропается (счётчик растёт), привязанный проходит. При остановленном backhaul selected-запрос завершается ошибкой и никогда не выходит с IP VPS2, трафик вне `seg-list` работает через VPS2. После перезапуска backhaul selected-трафик восстанавливается без перезапуска `sing-box`.

## 15. VPS1 — `seg-exit`

Первая реализация: клиент backhaul типа `amnezia` (`Type = amnezia` в `servers.txt`). Тип должен входить в список `Type` у `seg-gateway`.

На VPS1 не создаётся:

```text
awg0
```

Создаётся только:

```text
awg-backhaul
```

VPS1:

- инициирует соединение с VPS2;
- поддерживает `PersistentKeepalive`;
- выполняет forwarding;
- выполняет NAT;
- предоставляет DNS resolver;
- выпускает selected traffic в Internet.

Входящие UDP/TCP сервисные порты VPS1 наружу не открываются: backhaul инициирует сам VPS1.

Установка в прототипе: сначала `upgrade.sh`, затем пакеты AmneziaWG (PPA `amnezia/ppa`), `unbound` и nftables-юниты; `awg-quick@awg-backhaul` включён в автозапуск.

## 16. Backhaul

Первая реализация:

```text
AmneziaWG
```

### VPS2

```text
interface = awg-backhaul
Table = off
listener
Endpoint VPS1 не задаётся
```

Peer VPS1:

```text
AllowedIPs = 0.0.0.0/0
```

`::/0` добавляется только при включении SEG IPv6.

### VPS1

```text
interface = awg-backhaul
Endpoint = VPS2:SEG_BACKHAUL_PORT
PersistentKeepalive = enabled
```

Peer VPS2:

```text
AllowedIPs = VPS2_BACKHAUL_IP/32
```

Backhaul использует собственные:

- keys;
- PSK;
- сеть;
- адреса;
- порт.

Параметры прототипа: сеть `10.77.0.0/30` (VPS2 `10.77.0.1`, VPS1 `10.77.0.2`), UDP-порт `42100` на VPS2, `MTU = 800`. Параметры AmneziaWG (`Jc`, `Jmin`, `Jmax`, `S1`–`S4`, `H1`–`H4`, `RandomTrailers`) одинаковы на обеих сторонах. `RandomTrailers = on` (обфускация), поэтому MTU уменьшен до 800, чтобы внешние пакеты не фрагментировались (раздел 13). Сеть не пересекается с сетью клиентов AWG (`10.7.0.0/24`).

Восстановление после перезапуска. VPS1 только инициирует соединение, а VPS2 не знает его Endpoint. После перезапуска `awg-backhaul` на VPS2 туннель мог оставаться нерабочим до ~3 минут, пока VPS1 сам не начинал новый handshake (`PersistentKeepalive = 25` этого не исправляет). Решение: на VPS1 служба `seg-exit-keepalive.service` (`ping -i 5 10.77.0.1`, `PartOf=awg-quick@awg-backhaul`). Восстановление сократилось до ~19 секунд. Пока есть трафик, AmneziaWG переустанавливает сессию примерно раз в 2 минуты.

## 17. DNS VPS1

DNS resolver слушает только backhaul-IP VPS1.

Разрешено:

```text
source = VPS2_BACKHAUL_IP
destination = VPS1_BACKHAUL_IP
DNS port
```

Остальные подключения к resolver запрещены.

DNS-запросы VPS1 выполняются через его зарубежный Internet egress.

Реализация в прототипе: `unbound` слушает только `VPS1_BACKHAUL_IP` (`ip-freebind: yes`, чтобы служба стартовала до подъёма интерфейса), `access-control` разрешает только `VPS2_BACKHAUL_IP`, `do-ip6: no`. `systemd-resolved` на `127.0.0.53/54` не конфликтует. С `--no-install-recommends` нужен отдельный пакет `unbound-anchor`, а без `/var/lib/unbound/root.key` служба не запускается: файл создаётся командой `unbound-anchor -a` (код возврата 1 допустим) и передаётся пользователю `unbound`.

## 18. Безопасность VPS1

Из `awg-backhaul` запрещены:

- SSH;
- loopback;
- private networks;
- link-local;
- metadata;
- управляющие сети.

Разрешены:

```text
DNS от VPS2

FORWARD
  → Internet

RETURN
  → established/related
```

Реализация в прототипе (VPS1):

- `net.ipv4.ip_forward = 1`;
- таблица `inet seg_exit` (hook input и forward, приоритет `-10`): из `awg-backhaul` разрешён только DNS (udp/tcp 53) от `VPS2_BACKHAUL_IP` к `VPS1_BACKHAUL_IP`, остальное в INPUT дропается; в FORWARD разрешён только источник `VPS2_BACKHAUL_IP`, запрещены private, loopback, CGNAT, link-local, multicast, публичный IP VPS1, пересылка между backhaul-интерфейсами и IPv6;
- таблица `ip seg_exit_nat`: masquerade `VPS2_BACKHAUL_IP` при выходе не через `awg-backhaul`;
- юнит `seg-exit-fw.service` загружает таблицы до `awg-quick@awg-backhaul`.

UFW на VPS1 активен. DROP в nftables окончателен, но ACCEPT в таблице `seg_exit` не отменяет решение UFW, поэтому в UFW нужны явные правила: DNS (tcp и udp 53) из `awg-backhaul` от `VPS2_BACKHAUL_IP` к `VPS1_BACKHAUL_IP` и `route allow in on awg-backhaul out on <внешний интерфейс> from VPS2_BACKHAUL_IP`. Правило UFW `22/tcp` из «Anywhere» остаётся, поэтому SSH через backhaul закрывает только таблица `seg_exit`.

Проверено: DNS с VPS2 через VPS1 работает, запрос с другого source отклоняется, внешний IP через backhaul равен IP VPS1, metadata и SSH на backhaul-адрес VPS1 недоступны. Следствие запрета INPUT: ping VPS1 по backhaul не проходит, состояние проверяется по handshake и DNS.

## 19. REALITY

Параметры:

```text
private key
public key
shortId
server_name
dest
flow
fingerprint
```

x25519 keypair создаётся локальным `sing-box` (версия 1.14.4 входит в требования проекта, см. README).

`dest` должен быть доступен с VPS2.

Приватный ключ хранится:

- в локальном source of truth (`config/seg.env`);
- на VPS2.

Параметры прототипа: `server_name` и `dest` — `www.microsoft.com:443` (проверен с VPS2: TLS 1.3, ALPN h2; так же отвечают `www.apple.com`, `dl.google.com`, `www.cloudflare.com`), `flow = xtls-rprx-vision`, fingerprint клиента `chrome`, `short_id` — 8 байт hex. Ключи, UUID и `short_id` создаются локальным `sing-box generate reality-keypair`, `generate uuid`, `generate rand --hex 8`. Ошибки `REALITY: processed invalid connection` от посторонних сканеров в журнале VPS2 — штатный отказ неаутентифицированным клиентам.

## 20. Клиентские идентификаторы

Каждый SEG-клиент имеет отдельный:

```text
VLESS UUID
```

Реестр:

```text
clients/seg/*.json
```

Конфигурация пользователей VPS2 генерируется из этого реестра.

## 21. Версия списка

Каждый профиль связан с:

```text
segListVersion
segListSha256
```

После изменения `seg-list.json` профиль считается устаревшим.

Server-side `seg-list` применяется независимо от версии клиента: selected-ресурсы устаревшего клиента всё равно попадают на VPS1 по серверному списку, а прочий трафик обрабатывается по `SEG_UNMATCHED_POLICY`.

## 22. IPv6

DIRECT traffic клиента может использовать локальный IPv6.

Selected traffic использует IPv4, пока IPv6 egress VPS1 отдельно не включён и не проверен.

Для selected domain в этом режиме AAAA не используется.

Для включения SEG IPv6 отдельно настраиваются:

- backhaul IPv6;
- MTU backhaul не ниже 1280 (при `RandomTrailers = on` и `S4 = 144` это требует пересмотра `S4` или отказа от случайного хвоста, раздел 13);
- `AllowedIPs = ::/0` на VPS2;
- адрес VPS2 peer на VPS1;
- маршрутизация selected-трафика VPS2;
- VPS1 routing;
- fail-closed;
- DNS strategy.

## 23. Проверка состояния

```powershell
sync-servers.ps1 -Mode SEG -Check all
```

Проверяются:

```text
GATEWAY
EXIT
BACKHAUL
HANDSHAKE AGE
SELECTED ROUTING
DNS THROUGH BACKHAUL
VPS1 EXTERNAL IP
FAIL-CLOSED
UNMATCHED_DIRECT
SEG-LIST VERSION
SEG-LIST HASH
SECURITY
```

`-Check` не изменяет конфигурацию. `FAIL-CLOSED` проверяется пассивно: наличие и счётчики правила в таблице `seg_failclosed` и состояние `seg-failclosed.service`. `SELECTED ROUTING` — привязка selected outbound к `awg-backhaul` в конфиге `sing-box` и активный `awg-backhaul`. Активная проверка (остановка backhaul) выполняется вручную.

Возраст handshake в прототипе при работающем keepalive не превышал ~2 минут, поэтому предлагаемый порог предупреждения — более 180 секунд.

## 24. Порядок развёртывания

```text
1. Upgrade.
2. Установка пакетов и подготовка роли (`bootstrap-seg.sh`).
3. Hardening (`secure-seg.sh`).
4. Fail-closed VPS2.
5. Маршрутизация selected-трафика VPS2 (`bind_interface`, `rp_filter`, MTU).
6. awg-backhaul VPS2.
7. awg-backhaul VPS1.
8. NAT/firewall/DNS VPS1.
9. Проверка handshake.
10. Проверка DNS через VPS1.
11. Проверка external IP = VPS1.
12. sing-box VPS2.
13. VLESS/REALITY.
14. server-side seg-list.
15. итоговый -Check.
```

При ошибке выполняется rollback предыдущей рабочей конфигурации.

При первой неуспешной установке sing-box остаётся выключенным, fail-closed сохраняется.

## 25. Риски и ограничения

- VPS2 является единой точкой входа selected traffic.
- VPS1 является единой точкой выхода selected traffic.
- Неполный `seg-list` приводит к DIRECT-маршрутизации ресурса с клиента. Сервис использует много доменов: YouTube — `googlevideo.com`, `ytimg.com`, `ggpht.com`, `youtubei.googleapis.com`; ChatGPT — `openai.com`, `oaistatic.com`, `oaiusercontent.com`. Домен вне списка идёт DIRECT и может быть недоступен из РФ (на прототипе `youtube.ru` резолвится в адреса Google и не открывается).
- Регион выходного IP VPS1 определяет поведение сервисов: на прототипе Cloudflare определил VPS1 как `loc=IN`.
- VPS2 с ~0,9 ГБ RAM и без swap: `sing-box` занимает около 55 МБ, но обновления и сборка DKMS идут с малым запасом.
- Устаревший клиентский профиль может не содержать новые правила; selected-ресурсы при этом обслуживает серверный `seg-list`.
- Изменение доменов, CDN или IP сервисов требует обновления `seg-list`.
- Прямые IP-подключения требуют CIDR-правил.
- Приложенческий DoH/DoT может обходить доменную классификацию; ECH скрывает SNI, поэтому серверный sniffing не гарантирован.
- Страховочный DIRECT выпускает неклассифицированный трафик с IP VPS2; утёкший UUID превращает VPS2 в российский прокси.
- Ресурс из `seg-list`, переданный клиентом без домена и не покрытый CIDR, уходит DIRECT через VPS2.
- Ошибка FakeIP/reverse mapping может привести к неверной классификации.
- Ошибка передачи destination domain может привести к срабатыванию страховочной политики.
- Selected IPv6 не используется без проверенного IPv6 egress VPS1.
- Падение backhaul делает selected traffic недоступным.
- Блокировка VPS2 прекращает selected ingress.
- Блокировка VPS1 прекращает selected egress.
- DPI может обнаружить или заблокировать VLESS/REALITY или AmneziaWG.
- Ошибка настройки `bind_interface` или fail-closed может привести к утечке через VPS2.
- Компрометация VPS2 раскрывает REALITY и backhaul credentials.
- Компрометация VPS1 раскрывает backhaul credentials.
- MTU/MSS требуют согласованной настройки backhaul: при MTU по умолчанию (1420) внешние пакеты AmneziaWG фрагментируются (раздел 13).
- UDP-приложения требуют поддержки UDP/XUDP.

## 26. Документация

`README.md` является эксплуатационной документацией проекта и по завершении реализации должен покрывать всё, что описано в этом документе: режимы, `servers.txt`, `seg.env`, `seg-list.json`, клиентов, развёртывание, `-Check`, fail-closed, страховочный DIRECT, DNS, обновление, замену узлов, ротацию ключей и действия при компрометации.

`SEG.md` описывает архитектуру и требования; `README.md` — порядок работы. Расхождения между ними недопустимы.

## 27. Структура реализации

Режим VPN остаётся прежним. Режим SEG реализуется отдельными файлами, а `-Mode` служит единой точкой входа:

```text
scripts\seg\*.ps1       SEG-логика (sync, клиенты, профили)
scripts\lib\common.ps1  общие функции SEG-скриптов: журнал, подтверждения, awg, случайные значения, backup файлов env, сверка SHA-256 пакетов sing-box (SSH и upgrade-этап добавляются с sync-seg.ps1)
seg\sing-box.sha256     SHA-256 пакетов sing-box 1.14.4 и файлов в них
scripts\lib\servers.ps1 загрузчик servers.txt (разбор, валидация, выбор по режиму, миграция); используется и VPN-, и SEG-скриптами
scripts\lib\segenv.ps1  загрузчик и валидатор config/seg.env (SEG-скрипты)
scripts\lib\seglist.ps1 загрузчик и валидатор config/seg-list.json, SHA-256, генерация rule_set (SEG-скрипты)
scripts\lib\segclients.ps1 хранение SEG-клиентов (clients\seg), пользователи VLESS для VPS2, метаданные профилей (SEG-скрипты)
seg\*.sh                bootstrap-seg.sh, secure-seg.sh
seg\templates\*         шаблоны {{VAR}} конфигураций SEG (backhaul, nftables, unbound, sing-box, systemd)
```

Шаблоны получены из прототипа (раздел 28): отрисованные с значениями прототипа, они совпадают с работающими конфигурациями на VPS1 и VPS2 (конфигурации `sing-box` отличаются только тем, что `seg-list` задан через `rule_set`, см. раздел 12), клиентский профиль проходит `sing-box check`. Имена переменных — параметры `seg.env` (`SEG_*`) и адреса из `servers.txt` (`VPS1_PUBLIC_IP`, `VPS2_PUBLIC_IP`); `seg-list` подставляется JSON-фрагментами `rule_set` (раздел 7: `SEG_RULE_SETS_JSON`, `SEG_DOMAIN_RULE_SETS_JSON`, `SEG_ROUTE_RULE_SETS_JSON`, `SEG_POST_RESOLVE_RULES_JSON`), пользователи — `SEG_VLESS_USERS_JSON`. Политика `SEG_UNMATCHED_POLICY = block` в серверный шаблон ещё не включена и не проверялась (пункт 20).

Конфигурации SEG формируются из шаблонов `{{VAR}}`, зафиксированных по результатам прототипа (roadmap, пункт 0). Порядок и принципы реализации описаны в `roadmap.md`.

## 28. Результаты прототипа (этап 0)

Прототип выполнен на двух отдельных VPS (Ubuntu 24.04, 1 vCPU, ~1 ГБ RAM) и клиенте Windows. Рабочие VPN-серверы не затрагивались.

### Подтверждено

- backhaul AmneziaWG VPS1 → VPS2, инициация с VPS1, `Table = off`, восстановление после перезапуска (раздел 16);
- NAT и DNS resolver VPS1, доступный только VPS2 через backhaul (разделы 17, 18);
- VLESS + REALITY на VPS2, клиент `sing-box 1.14.4` с Windows (разделы 8, 19);
- fail-closed: nftables по `SEG_MARK`, порядок запуска после перезагрузки (раздел 14);
- `bind_interface` без отдельной таблицы маршрутизации (раздел 13);
- sniffing на VPS2 и сопоставление домена и CIDR с `seg-list` (раздел 12);
- клиентский TUN на Windows: FakeIP для `seg-list`, прямой DNS через DoH, остальной трафик DIRECT (разделы 8, 10);
- блокировка tcp/25 вне backhaul;
- установка `sing-box` из локально скачанного пакета: SHA-256 сверяется с релизом на ноутбуке и на VPS2 после копирования, загрузка с GitHub на VPS2 не используется.

### Отклонения от первоначального SEG.md

1. Таблица `seg` и `ip rule` не нужны: достаточно `bind_interface` (раздел 13).
2. Серверный конфиг проверяется Linux-бинарником `sing-box`, не Windows (раздел 11).
3. VPS1 нуждается в keepalive-пинге в backhaul (раздел 16).
4. UFW на VPS1 требует явных правил к таблице nftables (раздел 18).
5. Прямой DNS клиента на Windows — только DoH/DoT из-за `strict_route` (разделы 8, 10).
6. `unbound` на VPS1 требует `unbound-anchor` и `root.key` (раздел 17).
7. ICMP-ping VPS1 через backhaul не проходит; состояние проверяется по handshake и DNS (раздел 18).
8. MTU `awg-backhaul` задаётся явно (800) при `RandomTrailers = on`; при MTU по умолчанию (1420) внешние пакеты фрагментируются (раздел 13).
9. Счётчик `UNMATCHED_DIRECT` реализуется отдельной меткой `0x5e91` direct outbound (раздел 12).

### Команды проверки

Основа для `-Check` и тестов. Значения IP и порты берутся из `seg.env`.

```text
VPS2: awg show awg-backhaul latest-handshakes     возраст handshake = date +%s минус значение
VPS2: dig +short +time=5 +tries=1 @VPS1_BACKHAUL_IP example.com
VPS2: curl -s -m 10 --interface awg-backhaul https://api.ipify.org     = IP VPS1
VPS2: nft list counter inet seg_failclosed unmatched_direct     UNMATCHED_DIRECT
VPS2: nft list chain inet seg_failclosed output     правила и счётчики
VPS2: cat /sys/class/net/awg-backhaul/mtu     = SEG_BACKHAUL_MTU
VPS2/VPS1: nstat -az IpFragCreates IpReasmOKs     не растут при большой передаче (нет фрагментации)
VPS2: sysctl net.ipv4.conf.awg-backhaul.rp_filter     не равно 1
VPS2: systemctl is-active seg-failclosed awg-quick@awg-backhaul sing-box
VPS1: systemctl is-active seg-exit-fw awg-quick@awg-backhaul seg-exit-keepalive unbound
клиент: sing-box check -c <профиль>
клиент: curl через профиль к хосту из seg-list = IP VPS1, к хосту вне списка = ожидаемый IP
```

### Не проверено

- security hardening (`secure-seg.sh`) и UFW на VPS2;
- IPv6;
- UDP/XUDP через VLESS и поведение при ECH;
- клиентский профиль для устаревшего `seg-list`;