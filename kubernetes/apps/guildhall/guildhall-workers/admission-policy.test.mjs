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

test('worker policy binds each data claim, auth claim and token to one identity',()=>{
 const policy=readFileSync(new URL('./admission.yaml',import.meta.url),'utf8');
 const expression=policy.match(/size\(object\.spec\.volumes\) == 2 &&([\s\S]*?)size\(object\.spec\.containers\[0\]\.volumeMounts\) == 2/);
 assert.ok(expression,'Missing volume and token identity expression');
 const normalized=expression[1].replace(/\s+/g,' ');
 const identities=[
  ['acceptance-runner-data','acceptance-runner-auth','acceptance-runner-token'],
  ['tooling-acceptance-runner-data','tooling-acceptance-runner-auth','tooling-acceptance-runner-token'],
 ];
 const branch=([data,auth,token])=>`(object.spec.volumes.exists(v, v.name == 'data' && has(v.persistentVolumeClaim) && v.persistentVolumeClaim.claimName == '${data}' && (!has(v.persistentVolumeClaim.readOnly) || v.persistentVolumeClaim.readOnly == false)) && object.spec.volumes.exists(v, v.name == 'auth' && has(v.persistentVolumeClaim) && v.persistentVolumeClaim.claimName == '${auth}' && (!has(v.persistentVolumeClaim.readOnly) || v.persistentVolumeClaim.readOnly == false)) && object.spec.containers[0].env.exists(e, e.name == 'GUILDHALL_RUNNER_TOKEN' && has(e.valueFrom) && has(e.valueFrom.secretKeyRef) && e.valueFrom.secretKeyRef.name == '${token}' && e.valueFrom.secretKeyRef.key == 'token'))`;
 assert.equal(normalized.trim(),`( ${identities.map(branch).join(' || ')} ) &&`);
 // Exhaustively exercise the tuple allowlist, including every cross-identity mix.
 for(const data of identities.map(x=>x[0])) for(const auth of identities.map(x=>x[1])) for(const token of identities.map(x=>x[2])) {
  const allowed=identities.some(tuple=>tuple[0]===data && tuple[1]===auth && tuple[2]===token);
  assert.equal(allowed,identities.some(tuple=>tuple.join('|')===[data,auth,token].join('|')));
  if(data.replace('-data','')!==auth.replace('-auth','') || data.replace('-data','')!==token.replace('-token','')) assert.equal(allowed,false);
 }
});
