# SpaceGen — первый прототип словами

Это описание рабочего среза, а не архитектуры. Прототип должен за один запуск превратить YAML провайдера в три файла интеграции и понятный лог. Всё остальное — после того, как этот путь стабильно работает на двух разных спецификациях.

Нейросети не используются. Код генератора — Ruby. Выход детерминированный: один и тот же вход даёт один и тот же IR и одни и те же файлы.

---

## 1. Задача

Space Payments подключает провайдеров вручную: разработчик читает документацию и пишет Ruby-сервис с контрактом `Provider::BaseService`. Это 2–5 дней на интеграцию.

Прототип принимает `provider_api.yaml` и отдаёт:

1. `novapay_service.rb` — сервис с четырьмя методами контракта;
2. `INTEGRATION.md` — настройка, авторизация, методы, статусы, ошибки, подпись, конфиг шлюза;
3. `fixtures.json` — примеры запросов, ответов и callback с ожидаемым статусом операции.

Запуск:

```bash
./integrate --spec provider_api.yaml --provider novapay --lang ruby
```

`BaseService` в кейсе дан примером, не исходником платформы. Прототип генерирует класс **по этому примеру**. Если организаторы выдадут настоящий base class — меняется только шаблон сервиса, не парсер и не IR.

---

## 2. На что делаем упор

Баллы стоят не на слоях и гемах, а на четырёх вещах:

| Упор | Зачем |
|---|---|
| Явный IR | Одна структура для любой спецификации. Парсер можно заменить, правила — нет. |
| Правила, не эвристики «на глаз» | Классификация, статусы, поля, единицы, подпись — с приоритетом и fallback. |
| Трассировка эталона | Каждая строка примера NovaPay из кейса объясняется правилом. |
| Честный unknown | Не узнали — warning и заглушка, генерация не падает. |

Не входит в прототип и не описывается как ценность: hexagonal, dry-rb стек, Steep/RBS, mutation testing, плагины TypeScript/Kotlin, Docker, интерактивные вопросы на демо.

---

## 3. Вход

Кейс называет `provider_api.yaml` «текстовым файлом с инструкцией», не OpenAPI. Прототип не ставит всё на один формат.

Два входа, один IR:

**A. OpenAPI 3.x** — если есть ключ `openapi: 3.x`.
**B. Плоский YAML** — если есть `base_url` / `endpoints` / `auth` без `openapi`.

Если формат не распознан — ошибка парсера с текстом, без стека исключений:

```
Неизвестный формат spec.
Ожидается OpenAPI 3.x (ключ openapi) или плоский YAML (ключи base_url, endpoints).
```

Сломанный YAML — отдельная ошибка с номером строки.

Из спецификации забираем только то, что нужно контракту:

- базовый URL;
- методы, пути, параметры, тела, ответы;
- схемы полей (тип, required, minimum/maximum/pattern/enum, format);
- авторизацию;
- статусы операций;
- ошибки (HTTP и коды провайдера);
- webhook и подпись;
- примеры (`example` / `examples`), если есть;
- заголовок идемпотентности, если есть.

`oneOf` / `anyOf` / `allOf` в прототипе не разбираются. Пишем warning и берём первый конкретный вариант либо помечаем поле как `unresolved`.

---

## 4. IR — продукт прототипа

После парсинга и правил на диске (и в памяти) лежит один JSON. Генераторы читают только его. Если правило сомневается — в IR есть `warnings`, а не «тихий дефолт без следа».

### 4.1. Схема

```text
ir
├── provider
│     name, class_name, base_url, base_url_env
├── auth
│     type, in, name, credentials_key
├── endpoints[]
│     role, method, path, operation_id
│     idempotency { header | null }
│     path_params[], query_params[]
│     request { content_type, fields[] }
│     responses[] { http_status, fields[], example }
├── field_map[]          # куда в payload класть данные operation
├── status_map{}         # статус провайдера → in_progress | approved | rejected
├── error_map[]          # HTTP / код провайдера → внутренний код + действие
├── webhook
│     path, header, algorithm, encoding
│     events[] { provider_event → approve | reject, id_field }
├── conditions[]         # предпроверки для check_conditions
├── gateway              # черновик ProviderGateway, может быть пустым
└── warnings[]           # code, message, path
```

Роли эндпоинта: `create` | `fetch` | `cancel` | `webhook` | `unknown`.

Внутренние статусы Space Payments только три: `in_progress`, `approved`, `rejected`.

Действия по ошибке: `reject` | `retry` | `retry_backoff` | `alert_ops`.

### 4.2. Эталонный IR для примера из кейса

Ниже — то, что прототип должен получить из NovaPay-подобной спецификации. Это не «пример архитектуры», это контракт генератора.

```json
{
  "provider": {
    "name": "novapay",
    "class_name": "NovapayService",
    "base_url": "https://api.sandbox.novapay.example/v1",
    "base_url_env": "NOVAPAY_BASE_URL"
  },
  "auth": {
    "type": "api_key",
    "in": "header",
    "name": "X-API-Key",
    "credentials_key": "api_key"
  },
  "endpoints": [
    {
      "role": "create",
      "method": "POST",
      "path": "/payouts",
      "operation_id": "create_payout",
      "idempotency": { "header": "Idempotency-Key" }
    },
    {
      "role": "fetch",
      "method": "GET",
      "path": "/payouts/{id}",
      "operation_id": "get_status",
      "idempotency": null
    },
    {
      "role": "cancel",
      "method": "POST",
      "path": "/payouts/{id}/cancel",
      "operation_id": "cancel",
      "idempotency": null
    },
    {
      "role": "webhook",
      "method": "POST",
      "path": "/webhooks/payout",
      "operation_id": "webhook",
      "idempotency": null
    },
    {
      "role": "unknown",
      "method": "GET",
      "path": "/balance",
      "operation_id": "get_balance",
      "idempotency": null
    }
  ],
  "field_map": [
    {
      "target": "amount",
      "source": "operation.amount",
      "transform": "to_minor_units",
      "required": true
    },
    {
      "target": "currency",
      "source": "literal:RUB",
      "required": true
    },
    {
      "target": "external_id",
      "source": "operation.id",
      "required": true
    },
    {
      "target": "recipient.type",
      "source": "literal:sbp",
      "required": true
    },
    {
      "target": "recipient.phone",
      "source": "operation.payout_requisite.sbp.phone",
      "required": true
    },
    {
      "target": "recipient.bank_code",
      "source": "operation.payout_requisite.sbp.bank_code",
      "required": true
    },
    {
      "target": "recipient.bank_name",
      "source": "operation.payout_requisite.sbp.bank_name",
      "required": false
    }
  ],
  "status_map": {
    "pending": "in_progress",
    "processing": "in_progress",
    "completed": "approved",
    "failed": "rejected",
    "cancelled": "rejected"
  },
  "error_map": [
    { "http": 400, "provider_code": "validation_error", "internal": "validation_error", "action": "reject" },
    { "http": 401, "provider_code": "unauthorized", "internal": "invalid_credentials", "action": "alert_ops" },
    { "http": 402, "provider_code": "insufficient_balance", "internal": "insufficient_balance", "action": "retry" },
    { "http": 422, "provider_code": "validation_error", "internal": "validation_error", "action": "reject" },
    { "http": 429, "provider_code": "rate_limit_exceeded", "internal": "rate_limit", "action": "retry_backoff" },
    { "http": 500, "provider_code": "internal_error", "internal": "internal_error", "action": "retry" }
  ],
  "webhook": {
    "path": "/webhooks/payout",
    "header": "X-NovaPay-Signature",
    "algorithm": "HMAC-SHA256",
    "encoding": "hex",
    "events": [
      { "provider_event": "payout.completed", "action": "approve", "id_field": "payout_id" },
      { "provider_event": "payout.failed", "action": "reject", "id_field": "payout_id" }
    ]
  },
  "conditions": [
    { "field": "operation.amount", "op": ">=", "value": 1000, "error": "amount_too_low" }
  ],
  "gateway": {
    "external_method": "sbp_payout",
    "gateway": "RUB_SBP_WITHDRAW"
  },
  "warnings": [
    {
      "code": "unmapped_endpoint",
      "message": "GET /balance не сопоставлен с контрактом BaseService и пропущен в сервисе",
      "path": "/balance"
    }
  ]
}
```

`GET /balance` не выбрасывается из IR: он остаётся с ролью `unknown` и попадает в warning и в таблицу методов `INTEGRATION.md`. В Ruby-сервис не генерируется четвёртый «лишний» публичный метод.

---

## 5. Правила

Правила применяются по порядку. Верхний пункт побеждает. Если ничего не сработало — `unknown` / warning, не догадка.

Переопределения из `.spacegen.yml` всегда приоритетнее автоматики. На демо и в CI интерактивных вопросов нет: только правила, конфиг и warnings.

### 5.1. Классификация эндпоинтов

1. Явная роль в `.spacegen.yml` (`endpoints["POST /payouts"] = create`).
2. Тег или `operationId`: `webhook` / `callback` / `notify` → `webhook`; `status` / `getPayment` / `getPayout` → `fetch`; `cancel` / `refund` / `reverse` → `cancel`; `create` / `payout` / `payment` / `deposit` + не GET → кандидат в `create`.
3. Форма пути и метод:
   - `POST` на коллекцию (`/payouts`, `/payments`) → `create`;
   - `GET` на ресурс с `{id}` → `fetch`;
   - `POST`/`PATCH` на `.../cancel|refund|reverse` → `cancel`;
   - путь содержит `webhook` / `callback` / `notify` → `webhook`.
4. Иначе `unknown` + warning.

Нельзя решать роль одним словом `payment` в пути: `GET /payments/{id}` — это `fetch`, не `create`. Сначала форма пути и метод, слова — уточнение.

Контракту нужны `create`, `fetch`, `webhook`. Если какой-то из трёх не найден:

- метод в сервисе всё равно есть;
- внутри — `failure(:unprocessable_entity, 'not_inferred')` и комментарий `TODO`;
- в логе CLI — ошибка уровня warning, не abort.

`cancel` в эталоне кейса есть в документации, в публичном контракте `BaseService` — нет. Прототип кладёт cancel в IR и в `INTEGRATION.md`. В сервис — только приватный метод или секция «не в контракте», без ломания четырёх обязательных методов.

### 5.2. Авторизация

| Что в spec | Что в IR |
|---|---|
| `apiKey` в header | `type: api_key`, `in: header`, имя заголовка |
| `apiKey` в query | то же, `in: query` |
| `http` + `bearer` | `type: bearer` |
| `oauth2` | `type: oauth2` + warning: в прототипе генерируем Bearer-заголовок и пишем в MD, что токен надо получить снаружи |
| несколько схем | берём первую глобальную / на create; остальные — warning |

`credentials_key` по умолчанию: `api_key` / `token`. Хранение в MD всегда: `providers.credentials` (encrypted) — как в эталоне кейса.

### 5.3. Статусы

Источник enum (в порядке):

1. поле `status` в успешном ответе create/fetch;
2. таблица `statuses` в плоском YAML;
3. события webhook (`payout.completed` → completed-группа).

Синонимы:

| Группа провайдера | Внутренний статус |
|---|---|
| `pending`, `processing`, `created`, `accepted`, `in_progress`, `queued` | `in_progress` |
| `completed`, `success`, `succeeded`, `approved`, `done`, `paid` | `approved` |
| `failed`, `error`, `rejected`, `declined`, `cancelled`, `canceled`, `expired` | `rejected` |

Неизвестный статус → `in_progress` + warning `unknown_status`. На выплатах безопаснее оставить «ещё в работе», чем одобрить.

### 5.4. Ошибки

Из `responses` create/fetch: 400, 401, 402, 403, 404, 409, 422, 429, 5xx.

| HTTP | Внутренний код | Действие |
|---|---|---|
| 400, 422 | `validation_error` | `reject` |
| 401, 403 | `invalid_credentials` | `alert_ops` |
| 402 | `insufficient_balance` | `retry` |
| 429 | `rate_limit` | `retry_backoff` |
| 5xx | `internal_error` | `retry` |
| 404 | `not_found` | `reject` |

Код провайдера берём из schema.error.code / body.code, если есть; иначе повторяем внутренний.

В сервисе:

- 429 → `rescue Provider::RateLimitError` / `failure(:too_many_requests, 'provider.rate_limit')`;
- 401 → `rescue Provider::UnauthorizedError` / `failure(:unauthorized, 'provider.invalid_credentials')`;
- остальные — через `ERROR_MAP` после разбора ответа.

### 5.5. Поля и единицы

Маппинг полей — отдельный слой, не «скопировать имена из OpenAPI».

Поиск источника для типичных целей:

| Цель в payload | Ищем в схеме / operation |
|---|---|
| `amount` | `amount`, `sum`, `value` |
| `currency` | `currency`, `ccy`; если одно значение в enum — `literal` |
| `external_id` | `external_id`, `order_id`, `merchant_id`, `idempotency_key` → `operation.id` |
| `id` в fetch | `{id}` в пути → `operation.provider_operation_id` |
| получатель | объект `recipient` / `destination` / `payee` / `sbp` |

Вложенность сохраняем: `recipient.phone` остаётся вложенным в payload.

Реквизиты Space Payments в эталоне лежат в `operation.payout_requisite.dig('sbp', ...)`. Если в схеме видны `phone`, `bank_code`, `bank_name` и тип SBP/телефон — кладём в `operation.payout_requisite.sbp.*`. Если метод не SBP и это неясно — плоские `operation.payout_requisite['phone']` + warning `requisite_shape_guessed`.

Единицы amount:

1. В описании/формате есть `kopeck`, `cent`, `minor`, `int64` денег без decimal — `to_minor_units` (`* 100`);
2. Тип `number` / `float` / decimal — без умножения;
3. Неясно — без умножения + warning `amount_unit_unresolved`.

Обязательность: поле в `required` схемы create → `required: true` в `field_map` и проверка в `check_conditions` (отсутствие реквизита). Необязательные в payload не подставляем пустой строкой: ключ опускаем.

### 5.6. Webhook и подпись

Признаки webhook: роль из §5.1, либо заголовок `*Signature*` / `*Webhook-Signature*`.

Алгоритм:

1. в описании/схеме есть `HMAC-SHA256` / `sha256` — берём;
2. иначе `HMAC-SHA256` + warning `signature_algo_defaulted`.

Кодировка: `hex`, если не сказано `base64`.

События: поле `event` / `type` / `status`.  
`completed`-группа → `approve_operation(id)`.  
`failed`-группа → `reject_operation(id, error_code)`.  
Прочее → `failure(:unprocessable_entity, 'unknown_event')`.

Поле id: `payout_id`, `payment_id`, `id`, `operation_id` — первое найденное.

### 5.7. `check_conditions`

Всегда вызываем `super` и выходим, если base уже failed — как в эталоне.

Дальше из схемы create:

- `minimum` / `exclusiveMinimum` по amount;
- `maximum`;
- `pattern` по строковым реквизитам — только если паттерн простой и попал в field_map.

Пример: `amount.minimum = 1000` → `return failure(:unprocessable_entity, 'amount_too_low') if operation.amount < 1000`.

### 5.8. Идемпотентность

Идемпотентность — это заголовок, не «у POST есть тело».

Ищем `Idempotency-Key`, `X-Idempotency-Key`, `Idempotency-Key` в parameters create. Если нашли — в IR `idempotency.header`, в MD колонка заполнена, в `create_request` заголовок добавлен. Если нет — прочерк в MD, в коде ничего не выдумываем.

---

## 6. Трассировка эталона кейса

Если правило не объясняет строку эталона — правила ещё нет. Это главный тест описания.

| Фрагмент выхода | Правило |
|---|---|
| `class NovapayService < BaseService` | `--provider novapay` → `class_name` |
| `BASE_URL = ENV.fetch('NOVAPAY_BASE_URL', 'https://...')` | `servers[0].url` + `NAME_BASE_URL` |
| `client.post(..., headers: auth_headers)` | роль `create`, `auth` api_key |
| `client.get(".../payouts/#{operation.provider_operation_id}")` | роль `fetch`, path param `{id}` |
| `verify_signature!` HMAC-SHA256, `X-NovaPay-Signature` | webhook header + algo |
| `payout.completed` → `approve_operation` | событие completed-группы |
| `payout.failed` → `reject_operation(..., error.code)` | событие failed-группы |
| `super` затем `amount < 1000` | §5.7 |
| `amount: (operation.amount * 100).to_i` | `to_minor_units` |
| `currency: 'RUB'` | единственный enum / literal |
| `external_id: operation.id` | синоним external_id |
| `recipient.phone` из `payout_requisite.dig('sbp', 'phone')` | SBP-реквизиты |
| `STATUS_MAP['pending'] = 'in_progress'` | §5.3 |
| `ERROR_MAP[429] = 'rate_limit'` | §5.4 |
| `Idempotency-Key` в таблице методов | §5.8 |
| `{ "external_method": "sbp_payout", "gateway": "RUB_SBP_WITHDRAW" }` | эвристика шлюза или `.spacegen.yml`; если не вывести — блок в MD с `TODO` и warning |

Шлюз в прототипе **не угадываем из воздуха**. Если в spec/конфиге нет `external_method` / `gateway` — warning `gateway_unresolved` и в MD явный TODO. Выдуманный `RUB_SBP_WITHDRAW` допустим только когда конфиг или плоский YAML это сказал, либо в фикстуре эталона для самопроверки генератора.

---

## 7. Выход — чеклист, не «шаблон есть»

### 7.1. Сервис

В файле всегда есть:

- класс `Provider::<Name>Service < BaseService`;
- `BASE_URL` из env с дефолтом из spec;
- `create_request`, `fetch_status`, `process_callback`, `check_conditions`;
- сбор payload по `field_map`;
- разбор ответа create (внешний id + статус);
- `map_status` через `STATUS_MAP`;
- `ERROR_MAP` и два `rescue` из эталона, если такие коды были в spec;
- `verify_signature!`, если в IR есть webhook.header;
- `auth_headers` по `auth`;
- константы `STATUS_MAP`, `ERROR_MAP`.

После записи: `ruby -c` на файл. Если синтаксис сломан — ошибка генератора, файлы всё равно лежат на диске, в логе `syntax: FAIL`. Отдельный AST-обход не нужен: достаточно синтаксиса и наличия четырёх `def`.

### 7.2. `INTEGRATION.md`

Секции как в кейсе, без лишних глав:

1. Авторизация — тип, заголовок/query, где хранятся credentials;
2. Методы — таблица: метод, endpoint, назначение, idempotency;
3. Маппинг статусов — две колонки;
4. Ошибки — HTTP, код провайдера, действие;
5. ProviderGateway config — JSON или TODO;
6. Webhook signature — формула `HMAC-SHA256(body, callback_secret) → encoding → Header`.

Если секция пустая из-за дырки в spec — секция остаётся и содержит warning текстом, не пропадает.

### 7.3. `fixtures.json`

Не «string → test_string». Нужны сценарии эталона:

- `create_request.request` — валидный payload по field_map;
- `create_request.response_201` (или первый success-код из spec);
- `create_request.response_422` (или первый клиентский error);
- `fetch_status.response_200`;
- `callback` + `expected_operation_status: approved`;
- `callback_failed` + `expected_operation_status: rejected`.

Если в spec есть `example` — берём его. Если нет — собираем из типов и field_map: amount в минорах как в payload, телефон-заглушка, id вида `op_abc123` / `np_7f3a9b2c` только как стабильные плейсхолдеры генератора (фиксируем в шаблоне, чтобы выход был детерминированным).

### 7.4. CLI

Одна команда, один процесс, три файла. Лог близко к кейсу:

```text
$ ./integrate --spec provider_api.yaml --provider novapay --lang ruby
Parsing spec...
Format: OpenAPI 3.0.3
Found 5 endpoints: POST /payouts, GET /payouts/{id}, POST /payouts/{id}/cancel, POST /webhooks/payout, GET /balance
Auth: ApiKeyAuth (header: X-API-Key)
Webhook signature: X-NovaPay-Signature (HMAC-SHA256)
Warnings:
  - GET /balance: unmapped_endpoint
Generating service...
Generating integration guide...
Generating test fixtures...
ruby -c: OK
Output:
  ./output/novapay_service.rb
  ./output/INTEGRATION.md
  ./output/fixtures.json
```

`--lang ruby` принимаем и игнорируем другие языки сообщением `only ruby is supported`.  
Неинтерактивно. Код выхода `0`, если файлы записаны; `1` только если YAML не прочитался или формат неизвестен. Warnings не делают `1`.

Дополнительно для чекпоинта, не вместо generate:

```bash
./integrate parse --spec provider_api.yaml
```

Печатает IR JSON в stdout / `./output/ir.json`. Так показывают, что разбор отделён от шаблона.

---

## 8. Переопределения

Файл `.spacegen.yml` рядом со spec или путь `--config`. Пример того, что имеет смысл в прототипе:

```yaml
provider: novapay
endpoints:
  "POST /payouts": create
  "GET /payouts/{id}": fetch
  "POST /webhooks/payout": webhook
status_map:
  ok: approved
field_map:
  amount:
    source: operation.amount
    transform: to_minor_units
gateway:
  external_method: sbp_payout
  gateway: RUB_SBP_WITHDRAW
```

Без этого файла генератор обязан работать. Конфиг — страховка универсальности, не костыль «под одного провайдера в коде».

---

## 9. Границы прототипа

Делаем:

- два адаптера входа → один IR;
- правила §5;
- три артефакта + CLI + `parse`;
- warnings;
- `.spacegen.yml`;
- `ruby -c`;
- два встроенных примера spec (NovaPay-подобный и второй, с другим набором методов и Bearer), чтобы на демо не было «работает только эталон».

Не делаем в этом срезе:

- LLM и любые модели;
- веб-UI;
- отдельные парсеры OpenAPI 3.0 vs 3.1;
- разбор `oneOf`/`anyOf`;
- генерацию RSpec;
- plugin system;
- интерактивный tty-prompt;
- статическую типизацию, mutation testing, DI-контейнер.

Это не «потом добавим и станет архитектурой». Это сознательный вырез, чтобы успеть качество разбора и маппинга.

---

## 10. Как собирается прототип по шагам

Шаги линейные. Каждый оставляет артефакт, который можно показать.

**Срез A — разбор.**  
YAML → адаптер A или B → сырое дерево → IR без ролей и карт, но уже с endpoints, schemas, security. Команда `parse` пишет JSON. Демо: «вот пять путей и apiKey».

**Срез B — правила.**  
Тот же JSON после классификатора, status_map, error_map, field_map, webhook, conditions, warnings. Демо: «вот create/fetch/webhook, баланс unknown, amount ×100».

**Срез C — генерация.**  
Три ERB-шаблона читают только IR. Появление файлов + `ruby -c` + лог как в кейсе. Демо: прогон эталона и второго YAML.

Порядок на защите: два YAML подряд, открыть сервис, открыть MD, открыть fixtures, показать warning на лишнем эндпоинте. Не Makefile с linters.

---

## 11. Критерии — чем закрываем, без оценки самим себе

Чекпоинты экспертов и защита жюри чуть по-разному режут те же 100 баллов. Прототип целится в содержание, не в таблицу «нам 20 из 20».

| О чём спрашивают | Что должно быть видно в прототипе |
|---|---|
| Разбор API | Методы, параметры, auth, статусы, ошибки, webhook; `parse` показывает это в IR |
| Генерация сервиса | Четыре метода, запрос, статус, ошибки, callback, URL/headers из конфига |
| Преобразование данных | status_map, field_map, миноры, required/optional |
| Универсальность | второй YAML, логика в правилах, unknown + warning, `.spacegen.yml` |
| Доки и фикстуры | шесть секций MD, сценарии fixtures как в кейсе |
| Запуск | одна команда, один процесс, понятный лог и ошибка парсера |
| Качество | `parser` / `ir` / `rules` / `generators` / `cli`, ошибки чтения YAML |

Отраслевые баллы в прототипе зарабатываются не «у нас mutant», а тем, что в домене выплат уже есть: подпись webhook, идемпотентность, копейки, retry на 429, SBP-реквизиты, явные warnings.

---

## 12. Риски, которые прототип принимает заранее

| Риск | Как живём с ним |
|---|---|
| На чекпоинте дадут не OpenAPI | Адаптер B, тот же IR |
| Эндпоинты названы странно | Форма пути важнее слова; конфиг перекрывает |
| Единицы amount не написаны | Не умножаем, пишем warning |
| Нет таблицы статусов | Синонимы + default `in_progress` |
| Нет настоящего `BaseService` | Генерируем по примеру кейса, шаблон один |
| Шлюз в кейсе выглядит магически | Не выдумываем; TODO в MD |

Если не хватает времени — режем в обратном порядке: сначала оставляем IR + сервис + CLI, потом MD, потом fixtures. Сервис без IR «захардкоженный под NovaPay» не показываем: это провал универсальности.
