#!/usr/bin/env node
// One-time (and re-runnable) Telegram bot setup:
//   1. point the bot's webhook at the deployed telegramWebhook function
//   2. register the command list shown in Telegram's "/" menu
//
// The bot token is a Secret Manager secret at runtime, so it isn't available to
// this script automatically — pass it in the environment:
//
//   TELEGRAM_BOT_TOKEN=123:ABC \
//   TELEGRAM_WEBHOOK_SECRET=$(openssl rand -hex 32) \
//   WEBHOOK_URL=https://us-central1-fittrack-dev-3a3c5.cloudfunctions.net/telegramWebhook \
//   node scripts/setup-telegram.mjs
//
// Use the SAME TELEGRAM_WEBHOOK_SECRET value you stored with
// `firebase functions:secrets:set TELEGRAM_WEBHOOK_SECRET` — Telegram echoes it
// back on every delivery and the function rejects anything that doesn't match.
//
// Flags:
//   --info    print the current webhook status and exit
//   --delete  unregister the webhook (stops all deliveries)

const token = process.env.TELEGRAM_BOT_TOKEN;
const secret = process.env.TELEGRAM_WEBHOOK_SECRET;
const url = process.env.WEBHOOK_URL;

if (!token) {
  console.error('TELEGRAM_BOT_TOKEN is required (get it from @BotFather).');
  process.exit(1);
}

const api = async (method, body) => {
  const res = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body ?? {}),
  });
  const json = await res.json();
  if (!json.ok) throw new Error(`${method}: ${json.description}`);
  return json.result;
};

const COMMANDS = [
  { command: 'today', description: "Today's calories, protein and food log" },
  { command: 'workout', description: "Today's workout from your plan" },
  { command: 'weight', description: 'Log a weigh-in, e.g. /weight 72.5' },
  { command: 'log', description: 'Log food, e.g. /log 2 eggs and toast' },
  { command: 'undo', description: 'Remove the last thing you logged today' },
  { command: 'help', description: 'What this bot understands' },
  { command: 'unlink', description: 'Disconnect this chat from your account' },
];

const args = process.argv.slice(2);

if (args.includes('--info')) {
  const info = await api('getWebhookInfo');
  console.log(JSON.stringify(info, null, 2));
  process.exit(0);
}

if (args.includes('--delete')) {
  await api('deleteWebhook', { drop_pending_updates: true });
  console.log('✅ Webhook removed — the bot will stop receiving updates.');
  process.exit(0);
}

if (!url || !secret) {
  console.error('WEBHOOK_URL and TELEGRAM_WEBHOOK_SECRET are required to register the webhook.');
  process.exit(1);
}

const me = await api('getMe');
console.log(`Bot: @${me.username} (${me.first_name})`);

await api('setWebhook', {
  url,
  secret_token: secret,
  // We only handle these two; anything else is delivery we'd pay for and drop.
  allowed_updates: ['message', 'callback_query'],
  drop_pending_updates: true,
});
console.log(`✅ Webhook set to ${url}`);

await api('setMyCommands', { commands: COMMANDS });
console.log(`✅ Registered ${COMMANDS.length} commands`);

console.log(
  `\nSet TELEGRAM_BOT_USERNAME=${me.username} in functions/.env so the app can build its deep link, then redeploy.`,
);
