import {test} from 'node:test';
import {strict as assert} from 'node:assert';
import {readFileSync} from 'node:fs';

// Static contract guard for Guildhall's worker egress policies. It does not evaluate CEL: `allowed`
// below is a JavaScript model of the six validations, checked against the policy Guildhall renders
// for this cluster (Guildhall packages/environments/src/fixtures/egress/home-cluster.json). Exercise
// real admission (server-side dry run) on the reviewed policy before relying on it.
const policyText=readFileSync(new URL('./egress-admission.yaml',import.meta.url),'utf8');
const access=readFileSync(new URL('./access.yaml',import.meta.url),'utf8');

const guildhallPolicy={apiVersion:'cilium.io/v2',kind:'CiliumNetworkPolicy',metadata:{name:'guildhall-egress-tooling-runner-04',namespace:'guildhall-workers'},spec:{
 description:'Guildhall network allowlist for worker tooling-runner-04, version 3.',
 endpointSelector:{matchLabels:{'app.kubernetes.io/name':'guildhall-runner','app.kubernetes.io/instance':'tooling-runner-04'}},
 egress:[
  {toEndpoints:[{matchLabels:{'k8s:io.kubernetes.pod.namespace':'kube-system','k8s:k8s-app':'kube-dns'}}],toPorts:[{ports:[{port:'53',protocol:'UDP'},{port:'53',protocol:'TCP'}],rules:{dns:[{matchPattern:'*'}]}}]},
  {toEndpoints:[{matchLabels:{'k8s:io.kubernetes.pod.namespace':'network','k8s:gateway.envoyproxy.io/owning-gateway-name':'envoy-internal'}}],toPorts:[{ports:[{port:'10443',protocol:'TCP'}]}]},
  {toFQDNs:[{matchName:'api.anthropic.com'},{matchName:'auth.openai.com'},{matchName:'chatgpt.com'},{matchName:'claude.ai'},{matchName:'guildhall.laboratory.casa'},{matchName:'platform.claude.com'}],toPorts:[{ports:[{port:'443',protocol:'TCP'}]}]},
  {toFQDNs:[{matchPattern:'**.githubusercontent.com'},{matchName:'example.com'}],toPorts:[{ports:[{port:'80',protocol:'TCP'},{port:'443',protocol:'TCP'}]}]},
 ]}};

const forbiddenRule=['authentication','icmps','toCIDR','toCIDRSet','toEntities','toGroups','toNodes','toRequires','toServices'];
const endpointOk=e=>!e.matchExpressions&&e.matchLabels&&Object.keys(e.matchLabels).length===2&&(
 (e.matchLabels['k8s:io.kubernetes.pod.namespace']==='kube-system'&&e.matchLabels['k8s:k8s-app']==='kube-dns')||
 (e.matchLabels['k8s:io.kubernetes.pod.namespace']==='network'&&e.matchLabels['k8s:gateway.envoyproxy.io/owning-gateway-name']==='envoy-internal'));
function allowed(object){
 const s=object.spec,labels=s?.endpointSelector?.matchLabels;
 if(object.specs||!s||!labels||s.endpointSelector.matchExpressions||Object.keys(labels).length!==2||labels['app.kubernetes.io/name']!=='guildhall-runner'||object.metadata.name!==`guildhall-egress-${labels['app.kubernetes.io/instance']}`)return 'selector';
 if(s.ingress||s.ingressDeny||s.egressDeny||s.nodeSelector||s.enableDefaultDeny||!s.egress?.length)return 'egress-only';
 if(!s.egress.every(r=>forbiddenRule.every(key=>!(key in r))&&(!!r.toEndpoints!==!!r.toFQDNs)))return 'rule-kind';
 if(!s.egress.every(r=>!r.toEndpoints||r.toEndpoints.every(endpointOk)))return 'endpoints';
 if(!s.egress.every(r=>r.toPorts&&r.toPorts.every(p=>!p.listener&&!p.originatingTLS&&!p.terminatingTLS&&!p.serverNames&&(!p.rules||(p.rules.dns&&!p.rules.http))&&p.ports&&p.ports.every(x=>!('endPort' in x)))))return 'ports';
 if(!s.egress.every(r=>!r.toFQDNs||r.toPorts.every(p=>!p.rules&&p.ports.every(x=>['80','443'].includes(x.port)&&x.protocol==='TCP'))))return 'fqdn-ports';
 return true;
}
const variant=change=>{const copy=structuredClone(guildhallPolicy);change(copy);return allowed(copy);};

test('every validation in the model is present in the admission policy',()=>{
 assert.match(policyText,/failurePolicy:\s*Fail/);
 assert.match(policyText,/request\.userInfo\.username == 'system:serviceaccount:guildhall:guildhall'/);
 assert.match(policyText,/resources: \[ciliumnetworkpolicies\]/);
 assert.match(policyText,/guildhall\.laboratory\.casa\/managed-workers: "true"/);
 for(const clause of [
  "object.metadata.name == 'guildhall-egress-' + object.spec.endpointSelector.matchLabels['app.kubernetes.io/instance']",
  "object.spec.endpointSelector.matchLabels['app.kubernetes.io/name'] == 'guildhall-runner'",
  'size(object.spec.endpointSelector.matchLabels) == 2',
  '!has(object.spec.ingress)','!has(object.spec.ingressDeny)','!has(object.spec.egressDeny)','!has(object.spec.nodeSelector)','!has(object.spec.enableDefaultDeny)',
  ...forbiddenRule.map(key=>`!has(r.${key})`),
  '(has(r.toEndpoints) != has(r.toFQDNs))',
  "e.matchLabels['k8s:k8s-app'] == 'kube-dns'",
  "e.matchLabels['k8s:gateway.envoyproxy.io/owning-gateway-name'] == 'envoy-internal'",
  '!has(p.listener)','!has(p.originatingTLS)','!has(p.terminatingTLS)','!has(p.serverNames)','!has(p.rules.http)','!has(x.endPort)',
  "x.port in ['80', '443'] && has(x.protocol) && x.protocol == 'TCP'",
 ])assert.ok(policyText.replace(/\s+/g,' ').includes(clause),`Missing admission constraint: ${clause}`);
});
test('the policy Guildhall renders for this cluster passes; widened policies do not',()=>{
 assert.equal(allowed(guildhallPolicy),true);
 assert.equal(variant(p=>{p.metadata.name='guildhall-egress-someone-else';}),'selector');
 assert.equal(variant(p=>{p.spec.endpointSelector.matchLabels={'app.kubernetes.io/name':'guildhall-runner'};p.metadata.name='guildhall-egress-undefined';}),'selector');
 assert.equal(variant(p=>{p.spec.endpointSelector.matchLabels['team']='x';}),'selector');
 assert.equal(variant(p=>{p.spec.ingress=[{fromEntities:['world']}];}),'egress-only');
 assert.equal(variant(p=>{p.spec.enableDefaultDeny={egress:false};}),'egress-only');
 assert.equal(variant(p=>{p.spec.egress.push({toEntities:['world']});}),'rule-kind');
 assert.equal(variant(p=>{p.spec.egress.push({toCIDR:['0.0.0.0/0']});}),'rule-kind');
 assert.equal(variant(p=>{p.spec.egress.push({toEndpoints:[{matchLabels:{'k8s:io.kubernetes.pod.namespace':'database','k8s:app':'postgres'}}],toPorts:[{ports:[{port:'5432',protocol:'TCP'}]}]});}),'endpoints');
 assert.equal(variant(p=>{p.spec.egress.push({toEndpoints:[{}],toPorts:[{ports:[{port:'443',protocol:'TCP'}]}]});}),'endpoints');
 assert.equal(variant(p=>{p.spec.egress[3].toPorts[0].ports.push({port:'22',protocol:'TCP'});}),'fqdn-ports');
 assert.equal(variant(p=>{p.spec.egress[2].toPorts[0].ports[0].endPort=65535;}),'ports');
 assert.equal(variant(p=>{p.spec.egress[2].toPorts[0].rules={http:[{}]};}),'ports');
});
test('Guildhall may manage only CiliumNetworkPolicies in the worker namespace, with apply verbs',()=>{
 assert.match(access,/kind: Role\n/);assert.doesNotMatch(access,/kind: ClusterRole/);
 assert.match(access,/- apiGroups: \[cilium\.io\]\n\s+resources: \[ciliumnetworkpolicies\]\n\s+verbs: \[create, get, patch, delete\]/);
 assert.doesNotMatch(access,/ciliumclusterwidenetworkpolicies|verbs: \[.*(\*|escalate|bind|list|watch|update).*\]/);
});
