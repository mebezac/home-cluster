import {test} from 'node:test';
import {strict as assert} from 'node:assert';
import {readFileSync} from 'node:fs';

// Static contract guard. This does not evaluate CEL; exercise real admission
// allow/deny cases on the reviewed policy before granting create permission.
test('worker policy pins the launcher label and claim ownership identity',()=>{
 const policy=readFileSync(new URL('./admission.yaml',import.meta.url),'utf8');
 for(const clause of [
  "object.metadata.labels['app.kubernetes.io/name'] == 'guildhall-runner'",
  'object.spec.securityContext.runAsNonRoot == true',
  'object.spec.securityContext.runAsUser == 3000',
  'object.spec.securityContext.runAsGroup == 3000',
  'object.spec.securityContext.fsGroup == 3000',
  "object.spec.securityContext.fsGroupChangePolicy == 'OnRootMismatch'",
  "object.spec.securityContext.seccompProfile.type == 'RuntimeDefault'",
  '!has(c.securityContext.runAsUser)', '!has(c.securityContext.runAsGroup)',
  '!has(c.securityContext.runAsNonRoot)', '!has(c.securityContext.seccompProfile)',
  'size(object.spec.securityContext.supplementalGroups) == 0'
 ]) assert.ok(policy.includes(clause),`Missing admission constraint: ${clause}`);
 assert.match(policy,/failurePolicy:\s*Fail/);
});
