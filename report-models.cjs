// Parse JSON without requiring jq or ripgrep. Do not print model instruction bodies.
const fs = require('node:fs');
const [target, ...files] = process.argv.slice(2);
const labels = ['新版内置目录', '刷新命令结果（可能回退到内置目录）', '实际磁盘缓存'];
let cached = false;
files.forEach((file, i) => {
  try {
    const data = JSON.parse(fs.readFileSync(file, 'utf8'));
    const models = Array.isArray(data) ? data : data.models;
    if (!Array.isArray(models)) throw new Error('无法识别目录格式');
    const model = models.find(m => m.slug === target || m.id === target);
    console.log(`${labels[i]}: ${model ? '包含' : '不包含'} ${target}`);
    if (data.client_version) console.log(`  client_version: ${data.client_version}`);
    if (data.fetched_at) console.log(`  fetched_at: ${data.fetched_at}`);
    if (model) {
      console.log(`  visibility: ${model.visibility ?? '未声明'}`);
      console.log(`  effort: ${(model.supported_reasoning_levels || []).map(x => x.effort).join(', ')}`);
      if (i === 2) cached = model.visibility === 'list';
    }
  } catch (error) {
    console.log(`${labels[i]}: ${error.code === 'ENOENT' ? '文件未生成' : error.message}`);
  }
});
if (!cached) {
  console.log('尚未确认目标模型进入可见缓存。请检查 refreshed.err 和后台版本；不要反复删除聊天历史。');
  process.exitCode = 3;
}
