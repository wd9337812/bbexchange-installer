#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require('fs');
const path = require('path');
const { usePostgres, getPool } = require('../apps/backend/src/postgresClient');
const { runAffiliateTransactionSync } = require('../apps/backend/src/affiliateTransactionSyncService');

function argValue(name, fallback = '') {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx < 0) return fallback;
  return process.argv[idx + 1] || fallback;
}

function asInt(v, fallback, min, max) {
  const n = Number(v);
  if (!Number.isFinite(n)) return fallback;
  const i = Math.floor(n);
  return Math.max(min, Math.min(max, i));
}

function nowStamp() {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

async function getCounts(pool) {
  const rs = await pool.query(`
    select
      count(*)::int as total_rows,
      coalesce(sum(case when mapped then 1 else 0 end),0)::int as mapped_rows,
      coalesce(sum(case when not mapped then 1 else 0 end),0)::int as unmapped_rows,
      coalesce(sum(case when lower(coalesce(commission_status,'')) in ('approved','confirm','confirmed','paid','success','succeeded','settled','complete','completed','effective') then 1 else 0 end),0)::int as confirmed_rows,
      coalesce(sum(case when lower(coalesce(commission_status,'')) in ('reject','rejected','decline','declined','delete','deleted','deny','denied','cancel','canceled','cancelled','void','chargeback','refund','refunded','reverse','reversed','fail','failed','invalid','expired') then 1 else 0 end),0)::int as rejected_rows
    from affiliate_conversions
  `);
  return rs.rows[0] || {
    total_rows: 0,
    mapped_rows: 0,
    unmapped_rows: 0,
    confirmed_rows: 0,
    rejected_rows: 0
  };
}

function buildReportMarkdown(params) {
  const lines = [];
  lines.push('# Affiliate Transactions 回灌重建报告');
  lines.push('');
  lines.push(`- 生成时间: ${new Date().toISOString()}`);
  lines.push(`- 执行模式: ${params.mode}`);
  lines.push(`- 增量窗口(天): ${params.incrementalDays}`);
  lines.push(`- 对账窗口(天): ${params.reconcileDays}`);
  lines.push(`- 分页大小: ${params.pageSize}`);
  lines.push('');
  lines.push('## 重建前统计');
  lines.push('');
  lines.push(`- 总行数: ${params.before.total_rows}`);
  lines.push(`- 已归因: ${params.before.mapped_rows}`);
  lines.push(`- 未归因: ${params.before.unmapped_rows}`);
  lines.push(`- 已确认状态: ${params.before.confirmed_rows}`);
  lines.push(`- 拒绝状态: ${params.before.rejected_rows}`);
  lines.push('');
  lines.push('## 同步执行结果');
  lines.push('');
  if (params.syncResult) {
    lines.push(`- runId: ${params.syncResult.runId || '-'}`);
    lines.push(`- status: ${params.syncResult.status || '-'}`);
    lines.push(`- alliancesTotal: ${params.syncResult.alliancesTotal || 0}`);
    lines.push(`- alliancesSuccess: ${params.syncResult.alliancesSuccess || 0}`);
    lines.push(`- alliancesFailed: ${params.syncResult.alliancesFailed || 0}`);
    lines.push(`- pulledRows: ${params.syncResult.pulledRows || 0}`);
    lines.push(`- upsertedRows: ${params.syncResult.upsertedRows || 0}`);
    lines.push(`- mappedRows: ${params.syncResult.mappedRows || 0}`);
    lines.push(`- unmappedRows: ${params.syncResult.unmappedRows || 0}`);
    if (params.syncResult.errorMessage) {
      lines.push(`- errorMessage: ${params.syncResult.errorMessage}`);
    }
  } else {
    lines.push('- dry-run 未执行同步');
  }
  lines.push('');
  lines.push('## 重建后统计');
  lines.push('');
  lines.push(`- 总行数: ${params.after.total_rows}`);
  lines.push(`- 已归因: ${params.after.mapped_rows}`);
  lines.push(`- 未归因: ${params.after.unmapped_rows}`);
  lines.push(`- 已确认状态: ${params.after.confirmed_rows}`);
  lines.push(`- 拒绝状态: ${params.after.rejected_rows}`);
  lines.push('');
  return `${lines.join('\n')}\n`;
}

async function main() {
  const mode = String(argValue('mode', 'dry-run')).trim().toLowerCase(); // dry-run|apply
  const incrementalDays = asInt(argValue('incremental-days', '3650'), 3650, 1, 36500);
  const reconcileDays = asInt(argValue('reconcile-days', '3650'), 3650, 1, 36500);
  const pageSize = asInt(argValue('page-size', '1000'), 1000, 50, 2000);
  if (!['dry-run', 'apply'].includes(mode)) {
    throw new Error('mode must be dry-run or apply');
  }
  if (!usePostgres()) {
    throw new Error('this script requires STORAGE_MODE=postgres');
  }
  const pool = getPool();
  const before = await getCounts(pool);
  console.log('[rebuild] before counts:', before);

  let syncResult = null;
  if (mode === 'apply') {
    await pool.query('begin');
    try {
      await pool.query('delete from affiliate_conversions');
      await pool.query('commit');
    } catch (err) {
      await pool.query('rollback').catch(() => undefined);
      throw err;
    }
    const sync = await runAffiliateTransactionSync({
      triggerType: 'rebuild',
      config: {
        affiliateTxnSyncEnabled: true,
        affiliateTxnSyncIntervalMinutes: 1440,
        affiliateTxnIncrementalWindowDays: incrementalDays,
        affiliateTxnReconcileWindowDays: reconcileDays,
        affiliateTxnPageSize: pageSize
      }
    });
    if (!sync.ok) {
      throw new Error(`sync failed: ${sync.message || 'unknown'}`);
    }
    syncResult = sync.item || null;
    console.log('[rebuild] sync result:', syncResult);
  } else {
    console.log('[rebuild] dry-run mode, skip delete and sync');
  }

  const after = await getCounts(pool);
  console.log('[rebuild] after counts:', after);

  const reportDir = path.resolve(__dirname, '../docs/rebuild-reports');
  fs.mkdirSync(reportDir, { recursive: true });
  const reportPath = path.join(reportDir, `affiliate-rebuild-${nowStamp()}.md`);
  const report = buildReportMarkdown({
    mode,
    incrementalDays,
    reconcileDays,
    pageSize,
    before,
    syncResult,
    after
  });
  fs.writeFileSync(reportPath, report, 'utf8');
  console.log(`[rebuild] report: ${reportPath}`);

  await pool.end();
}

main().catch((err) => {
  console.error('[rebuild] failed:', err.message || err);
  process.exit(1);
});

