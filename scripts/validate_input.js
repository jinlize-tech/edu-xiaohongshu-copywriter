const fs = require('fs');
const contract = {"product_id":"JLZ-EDU-SK-004","product_type":"Skill","required_fields":["课程卖点","目标家长","城市与平台语气","活动信息","可用素材"],"output_fields":["多版标题","正文","封面文案","标签","互动提问和发布检查清单"],"primary_risk":"夸大效果或使用未授权素材","first_action":"请补充并确认缺失字段，再执行小红书招生文案"};

function emit(payload, exitCode) {
  console.log(JSON.stringify({ product_id: contract.product_id, product_type: contract.product_type, ...payload }, null, 2));
  process.exit(exitCode || 0);
}

let data;
try {
  data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
} catch (error) {
  emit({
    validation_status: 'INVALID_JSON',
    scenario_name: null,
    errors: ['输入文件不是有效JSON'],
    required_fields: contract.required_fields,
    recommended_next_action: '修正JSON格式后重新提交'
  }, 2);
}

if (!data || typeof data !== 'object' || Array.isArray(data)) {
  emit({
    validation_status: 'INVALID_STRUCTURE',
    scenario_name: null,
    errors: ['顶层必须是JSON对象'],
    required_fields: contract.required_fields,
    recommended_next_action: '按照输入契约重新组织资料'
  }, 2);
}

const inputs = data.inputs && typeof data.inputs === 'object' && !Array.isArray(data.inputs) ? data.inputs : {};
const scenarioName = typeof data.scenario_name === 'string' ? data.scenario_name : null;
const businessContext = typeof data.business_context === 'string' ? data.business_context : null;
const isMissing = value => value === undefined || value === null || value === '' || (Array.isArray(value) && value.length === 0);
const missingFields = contract.required_fields.filter(field => isMissing(inputs[field]));
const conflicts = Array.isArray(data.conflicts) ? data.conflicts.filter(Boolean) : [];
const dataStatus = data.data_status || 'confirmed';
const sensitiveKeyPattern = /(手机号|手机号码|身份证|家庭住址|银行卡|健康信息|联系电话|微信|邮箱|studentname|parentname|phone|mobile|email|address|idcard|bankcard)/i;
const sensitivePaths = [];
function scanSensitive(value, path) {
  if (Array.isArray(value)) {
    value.forEach((item, index) => scanSensitive(item, `${path}[${index}]`));
    return;
  }
  if (!value || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    const childPath = path ? `${path}.${key}` : key;
    if (sensitiveKeyPattern.test(key)) sensitivePaths.push(childPath);
    scanSensitive(child, childPath);
  }
}
scanSensitive(data.inputs || {}, 'inputs');
const containsSensitiveData = data.contains_sensitive_data === true || sensitivePaths.length > 0;

if (missingFields.length > 0) {
  emit({
    validation_status: 'NEEDS_INPUT',
    scenario_name: scenarioName,
    business_context: businessContext,
    missing_fields: missingFields,
    conflicts: conflicts,
    output_fields: contract.output_fields,
    primary_risk: contract.primary_risk,
    recommended_next_action: `请补充${missingFields.join('、')}，不得自行补造`
  }, 2);
}

if (conflicts.length > 0 || dataStatus !== 'confirmed') {
  emit({
    validation_status: 'NEEDS_CONFIRMATION',
    scenario_name: scenarioName,
    business_context: businessContext,
    missing_fields: [],
    conflicts: conflicts,
    data_status: dataStatus,
    output_fields: contract.output_fields,
    recommended_next_action: '请先确认相互冲突或未确认的数据口径'
  }, 2);
}

if (containsSensitiveData) {
  emit({
    validation_status: 'READY_WITH_PRIVACY_WARNING',
    scenario_name: scenarioName,
    business_context: businessContext,
    missing_fields: [],
    conflicts: [],
    privacy_warning: true,
    sensitive_field_paths: sensitivePaths,
    warning: '请先移除或脱敏身份证号、手机号、完整住址、健康信息等非必要个人数据',
    output_fields: contract.output_fields,
    recommended_next_action: contract.first_action
  }, 0);
}

emit({
  validation_status: 'READY_FOR_PROCESSING',
  scenario_name: scenarioName,
  business_context: businessContext,
  missing_fields: [],
  conflicts: [],
  output_fields: contract.output_fields,
  primary_risk: contract.primary_risk,
  recommended_next_action: contract.first_action
}, 0);
