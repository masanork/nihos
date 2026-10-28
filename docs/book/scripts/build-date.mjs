export function buildDate(environment = process.env, now = new Date()) {
  const epoch = environment.SOURCE_DATE_EPOCH;
  if (epoch !== undefined && !/^(0|[1-9]\d*)$/.test(epoch)) {
    throw new Error('SOURCE_DATE_EPOCH must be a nonnegative integer in seconds');
  }
  const date = epoch === undefined ? now : new Date(Number(epoch) * 1000);
  if (!Number.isFinite(date.getTime())) throw new Error('Invalid build date');
  return {
    builtAt: date.toISOString(),
    date: new Intl.DateTimeFormat('ja-JP', {
      timeZone: 'Asia/Tokyo', year: 'numeric', month: 'long', day: 'numeric'
    }).format(date),
    timeZone: 'Asia/Tokyo',
    sourceDateEpoch: epoch ?? null
  };
}
