# FitTrack Telegram bot

The bot is a second front-end onto the same data as the iOS app. It writes the
same Firestore documents (`users/{uid}/dayLogs/…/meals`, `weightEntries`,
`workoutSessions`), so a meal logged in Telegram appears in the app immediately,
and the app's targets and rollups apply unchanged.

## What the bot does

| Input | Result |
|---|---|
| `150g chicken thigh + 100g rice` | Gemini estimates the macros, IFCT grounds them, the bot shows the breakdown and waits for **Save**. |
| A photo of a plate (caption optional) | The same flow, with vision analysis. A caption such as "half of this" improves the portion estimate. |
| `72.4 kg` | Logs a weigh-in. |
| `/today` | Calories and protein against the targets, plus every item logged today. |
| `/workout` | Today's session from the current workout plan, with a **Mark done** button. |
| `/weight 72.5` | Logs a weigh-in and shows the change since the last one. |
| `/undo` | Removes the last item logged today. |
| `/help`, `/link`, `/unlink` | Help, account linking, disconnect. |

Nothing is saved until the user taps **Save**. The user can also change the meal
type before the save.

## Architecture

```
functions/src/telegram/
  config.ts    Secrets and parameters (bot token, webhook secret, bot username)
  types.ts     The subset of the Telegram Bot API that we use
  api.ts       Telegram client: sendMessage, editMessage*, getFile, ...
  linking.ts   Link codes, chat -> uid binding, unlink
  store.ts     Firestore reads and writes in the iOS app's document shapes
  format.ts    Message rendering (progress bars, cards, help text)
  router.ts    Dispatcher: commands, free text, photos, button callbacks
  webhook.ts   The HTTP entry point: authentication, deduplication, 200 response
  handlers.ts  Callables that the app uses: createTelegramLinkCode, unlinkTelegram
functions/scripts/setup-telegram.mjs   One command that registers the webhook
functions/src/ai/foodEstimate.ts       Estimation core, shared with the app's callables
```

The Firestore collections that only the server uses:

| Path | Content |
|---|---|
| `telegramLinks/{code}` | A single-use link code. It expires after 60 minutes (`CODE_TTL_MS` in `linking.ts`). |
| `telegramChats/{chatId}` | The `chatId -> uid` binding. This record authorizes the chat. |
| `telegramChats/{chatId}/pending/{id}` | An estimate that waits for the user to review it. |
| `telegramUpdates/{updateId}` | Deduplication records for webhook deliveries. |

Security Rules deny all client access to these collections. The Rules also block
the client from writing the `telegram` field on `users/{uid}`, because that field
authorizes a chat.

## Setup

### 1. Create the bot

1. Open Telegram and start a chat with [@BotFather](https://t.me/BotFather).
2. Send `/newbot`. Give a display name and a username. The username must end
   with `bot`, for example `LogFitnessBot`.
3. BotFather returns a token in the form `123456789:AAE...`. Keep it secret. The
   token gives full control of the bot.
4. Optional: send `/setuserpic` and `/setdescription` to BotFather.

### 2. Store the secrets

Run these commands in the repository root. The Firebase CLI must be logged in.

```bash
# The bot token from BotFather
npx firebase-tools functions:secrets:set TELEGRAM_BOT_TOKEN

# A random shared secret. Telegram sends it back in a header on every delivery.
openssl rand -hex 32          # copy the output
npx firebase-tools functions:secrets:set TELEGRAM_WEBHOOK_SECRET
```

Add the bot's public username to `functions/.env` (this file is gitignored):

```
TELEGRAM_BOT_USERNAME=LogFitnessBot
DEFAULT_TIMEZONE=Asia/Kolkata
```

`TELEGRAM_BOT_USERNAME` lets the app build the `t.me` deep link.
`DEFAULT_TIMEZONE` applies only to a user whose profile has no timezone. Each
user's device timezone is stored when the user connects Telegram.

### 3. Deploy the functions

```bash
cd functions
npm run deploy
```

The deployment creates the `telegramWebhook` HTTP function. Its URL is:

```
https://us-central1-fittrack-dev-3a3c5.cloudfunctions.net/telegramWebhook
```

### 4. Register the webhook

```bash
cd functions
TELEGRAM_BOT_TOKEN='123456789:AAE...' \
TELEGRAM_WEBHOOK_SECRET='<the same value you set in step 2>' \
WEBHOOK_URL='https://us-central1-fittrack-dev-3a3c5.cloudfunctions.net/telegramWebhook' \
node scripts/setup-telegram.mjs
```

The script points the webhook at the function and registers the command menu.
Run it again after you change the command list.

Other options:

```bash
TELEGRAM_BOT_TOKEN='...' node scripts/setup-telegram.mjs --info     # show status
TELEGRAM_BOT_TOKEN='...' node scripts/setup-telegram.mjs --delete   # stop deliveries
```

### 5. Deploy the Security Rules

```bash
npx firebase-tools deploy --only firestore:rules
```

### 6. Optional: add a TTL policy

The `telegramUpdates` collection holds one small document for each webhook
delivery. Each document has an `expiresAt` field. Add a Firestore TTL policy on
that field to delete the documents automatically:

```bash
gcloud firestore fields ttls update expiresAt \
  --collection-group=telegramUpdates --enable-ttl \
  --project=fittrack-dev-3a3c5
```

Without the policy the collection grows. It stays small, but it does not clean
itself.

## How a user connects

1. In the app: **Settings → Telegram → Connect**.
2. The app calls `createTelegramLinkCode`. The backend stores the device
   timezone on the profile and returns a 6-character code plus a `t.me` deep
   link.
3. The user taps **Open Telegram & connect**. Telegram opens the bot chat and
   sends `/start <code>` automatically. The user can also type `/link <code>`.
4. The backend redeems the code in a transaction and writes the binding. The
   code is single-use.
5. The Settings screen streams the profile, so it changes to the connected state
   without a refresh.

To disconnect, use **Disconnect** in the app or send `/unlink` to the bot. The
logged data stays.

## Notes for maintenance

- **Day boundaries.** The app buckets meals by device-local day. The server has
  no device, so it uses the `timeZone` field on the profile. The field is
  written when the user connects Telegram.
- **Deduplication.** Telegram stops waiting for a response after about 60
  seconds and delivers the update again. An AI estimate can take longer. The
  webhook claims each `update_id` with a `create()` call, so a second delivery
  does no work.
- **The webhook always answers 200** after it accepts an update. A non-2xx
  response makes Telegram retry, and a permanent error would retry forever.
- **Group chats are ignored.** The bot replies only in private chats, because a
  group would let several people write into one person's log.
- **Costs.** Each free-text message and each photo is one Gemini call. The
  webhook has `maxInstances: 10`.
