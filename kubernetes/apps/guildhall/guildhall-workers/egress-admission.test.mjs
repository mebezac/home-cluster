import {test} from 'node:test';
import {strict as assert} from 'node:assert';
import {readFileSync} from 'node:fs';

// Static contract guard for Guildhall's worker egress policies. It does not evaluate CEL: `allowed`
// below is a JavaScript model of the validations, checked against the policy Guildhall renders for
// this cluster (Guildhall packages/environments/src/fixtures/egress/home-cluster.json). Exercise real
// admission (server-side dry run) on the reviewed policy before relying on it.
const policyText=readFileSync(new URL('./egress-admission.yaml',import.meta.url),'utf8');
const flat=policyText.replace(/\s+/g,' ');
const access=readFileSync(new URL('./access.yaml',import.meta.url),'utf8');
const launch='0f6e2a52-7c1d-4e8b-9a3f-5b2c1d4e6f70';

const guildhallPolicy={apiVersion:'cilium.io/v2',kind:'CiliumNetworkPolicy',metadata:{name:`guildhall-egress-${launch}`,namespace:'guildhall-workers',labels:{'app.kubernetes.io/managed-by':'guildhall','app.kubernetes.io/name':'guildhall-runner','app.kubernetes.io/instance':'worker-04','guildhall/launch-id':launch}},spec:{
 description:'Guildhall network allowlist for worker tooling-runner-04, version 3.',
 endpointSelector:{matchLabels:{'app.kubernetes.io/name':'guildhall-runner','app.kubernetes.io/instance':'tooling-runner-04'}},
 egress:[
  {toEndpoints:[{matchLabels:{'k8s:io.kubernetes.pod.namespace':'kube-system','k8s:k8s-app':'kube-dns'}}],toPorts:[{ports:[{port:'53',protocol:'UDP'},{port:'53',protocol:'TCP'}],rules:{dns:[{matchPattern:'*'}]}}]},
  {toEndpoints:[{matchLabels:{'k8s:io.kubernetes.pod.namespace':'network','k8s:gateway.envoyproxy.io/owning-gateway-name':'envoy-internal'}}],toPorts:[{ports:[{port:'10443',protocol:'TCP'}],serverNames:['git.laboratory.casa','guildhall.laboratory.casa']}]},
  {toFQDNs:[{matchName:'api.anthropic.com'},{matchName:'auth.openai.com'},{matchName:'chatgpt.com'},{matchName:'claude.ai'},{matchName:'guildhall.laboratory.casa'},{matchName:'platform.claude.com'}],toPorts:[{ports:[{port:'443',protocol:'TCP'}]}]},
  {toFQDNs:[{matchPattern:'**.example.org'},{matchName:'example.com'}],toPorts:[{ports:[{port:'80',protocol:'TCP'},{port:'443',protocol:'TCP'}]}]},
 ]}};

const forbiddenRule=['authentication','icmps','toCIDR','toCIDRSet','toEntities','toGroups','toNodes','toRequires','toServices'];
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const dnsRule=r=>r.toEndpoints.every(e=>!e.matchExpressions&&e.matchLabels&&Object.keys(e.matchLabels).length===2&&e.matchLabels['k8s:io.kubernetes.pod.namespace']==='kube-system'&&e.matchLabels['k8s:k8s-app']==='kube-dns')&&r.toPorts.every(p=>!p.serverNames&&p.ports.every(x=>x.port==='53'&&['UDP','TCP'].includes(x.protocol)));
const gatewayRule=r=>r.toEndpoints.every(e=>!e.matchExpressions&&e.matchLabels&&Object.keys(e.matchLabels).length===2&&e.matchLabels['k8s:io.kubernetes.pod.namespace']==='network'&&e.matchLabels['k8s:gateway.envoyproxy.io/owning-gateway-name']==='envoy-internal')&&r.toPorts.every(p=>!p.rules&&p.ports.every(x=>x.port==='10443'&&x.protocol==='TCP')&&(!p.serverNames||(p.serverNames.length>0&&p.serverNames.every(n=>!n.includes('*')))));
function allowed(object){
 const s=object.spec,meta=object.metadata.labels??{},labels=s?.endpointSelector?.matchLabels;
 if(object.specs||!s||!uuid.test(meta['guildhall/launch-id']??'')||object.metadata.name!==`guildhall-egress-${meta['guildhall/launch-id']}`||meta['app.kubernetes.io/managed-by']!=='guildhall'||!labels||s.endpointSelector.matchExpressions||Object.keys(labels).length!==2||labels['app.kubernetes.io/name']!=='guildhall-runner'||!labels['app.kubernetes.io/instance'])return 'selector';
 if(s.ingress||s.ingressDeny||s.egressDeny||s.nodeSelector||s.enableDefaultDeny||!s.egress?.length)return 'egress-only';
 if(!s.egress.every(r=>forbiddenRule.every(key=>!(key in r))&&(!!r.toEndpoints!==!!r.toFQDNs)&&(!r.toEndpoints||r.toEndpoints.length>0)&&(!r.toFQDNs||r.toFQDNs.length>0)))return 'rule-kind';
 if(!s.egress.every(r=>r.toPorts?.length&&r.toPorts.every(p=>!p.listener&&!p.originatingTLS&&!p.terminatingTLS&&(!p.rules||(p.rules.dns&&!p.rules.http))&&p.ports?.length&&p.ports.every(x=>!('endPort' in x)&&x.protocol))))return 'ports';
 if(!s.egress.every(r=>!r.toEndpoints||dnsRule(r)||gatewayRule(r)))return 'endpoints';
 if(!s.egress.every(r=>!r.toFQDNs||(r.toFQDNs.every(f=>f.matchName||(f.matchPattern?.startsWith('**.')&&!f.matchPattern.slice(3).includes('*')&&f.matchPattern.slice(3).includes('.')))&&r.toPorts.every(p=>!p.rules&&!p.serverNames&&p.ports.every(x=>['80','443'].includes(x.port)&&x.protocol==='TCP')))))return 'fqdn';
 return true;
}
const variant=change=>{const copy=structuredClone(guildhallPolicy);change(copy);return allowed(copy);};
const deleteAllowed=old=>!!old&&old.metadata.name.startsWith('guildhall-egress-')&&old.metadata.labels?.['app.kubernetes.io/managed-by']==='guildhall'&&old.metadata.name===`guildhall-egress-${old.metadata.labels?.['guildhall/launch-id']}`;

test('every validation in the model is present in the admission policies',()=>{
 assert.equal((policyText.match(/failurePolicy:\s*Fail/g)??[]).length,2);
 assert.equal((policyText.match(/request\.userInfo\.username == 'system:serviceaccount:guildhall:guildhall'/g)??[]).length,2);
 assert.match(policyText,/operations: \[CREATE, UPDATE\]/);assert.match(policyText,/operations: \[DELETE\]/);
 assert.equal((policyText.match(/guildhall\.laboratory\.casa\/managed-workers: "true"/g)??[]).length,2);
 for(const clause of [
  "object.metadata.name == 'guildhall-egress-' + object.metadata.labels['guildhall/launch-id']",
  "object.metadata.labels['app.kubernetes.io/managed-by'] == 'guildhall'",
  "object.spec.endpointSelector.matchLabels['app.kubernetes.io/name'] == 'guildhall-runner'",
  'size(object.spec.endpointSelector.matchLabels) == 2',
  '!has(object.spec.ingress)','!has(object.spec.ingressDeny)','!has(object.spec.egressDeny)','!has(object.spec.nodeSelector)','!has(object.spec.enableDefaultDeny)',
  ...forbiddenRule.map(key=>`!has(r.${key})`),
  '(has(r.toEndpoints) != has(r.toFQDNs))','size(r.toEndpoints) > 0','size(r.toFQDNs) > 0',
  "e.matchLabels['k8s:k8s-app'] == 'kube-dns'","x.port == '53'",
  "e.matchLabels['k8s:gateway.envoyproxy.io/owning-gateway-name'] == 'envoy-internal'","x.port == '10443'","!n.contains('*')",
  '!has(p.listener)','!has(p.originatingTLS)','!has(p.terminatingTLS)','!has(p.rules.http)','!has(x.endPort)','has(x.protocol)',
  "f.matchPattern.startsWith('**.')","!f.matchPattern.substring(3).contains('*')",
  "x.port in ['80', '443'] && x.protocol == 'TCP'",
  "oldObject.metadata.name == 'guildhall-egress-' + oldObject.metadata.labels['guildhall/launch-id']",
 ])assert.ok(flat.includes(clause),`Missing admission constraint: ${clause}`);
});
test('the policy Guildhall renders for this cluster passes; widened policies do not',()=>{
 assert.equal(allowed(guildhallPolicy),true);
 assert.equal(variant(p=>{p.metadata.name='guildhall-egress-tooling-runner-04';}),'selector');
 assert.equal(variant(p=>{p.metadata.labels['guildhall/launch-id']='not-a-launch';p.metadata.name='guildhall-egress-not-a-launch';}),'selector');
 assert.equal(variant(p=>{p.spec.endpointSelector.matchLabels={'app.kubernetes.io/name':'guildhall-runner','team':'x'};}),'selector');
 assert.equal(variant(p=>{p.spec.endpointSelector.matchLabels['team']='x';}),'selector');
 assert.equal(variant(p=>{p.spec.ingress=[{fromEntities:['world']}];}),'egress-only');
 assert.equal(variant(p=>{p.spec.enableDefaultDeny={egress:false};}),'egress-only');
 assert.equal(variant(p=>{p.spec.egress.push({toEntities:['world']});}),'rule-kind');
 assert.equal(variant(p=>{p.spec.egress.push({toCIDR:['0.0.0.0/0']});}),'rule-kind');
 assert.equal(variant(p=>{p.spec.egress.push({toFQDNs:[],toPorts:[{ports:[{port:'443',protocol:'TCP'}]}]});}),'rule-kind');
 assert.equal(variant(p=>{p.spec.egress.push({toEndpoints:[],toPorts:[{ports:[{port:'443',protocol:'TCP'}]}]});}),'rule-kind');
 assert.equal(variant(p=>{p.spec.egress.push({toEndpoints:[{matchLabels:{'k8s:io.kubernetes.pod.namespace':'database','k8s:app':'postgres'}}],toPorts:[{ports:[{port:'5432',protocol:'TCP'}]}]});}),'endpoints');
 assert.equal(variant(p=>{p.spec.egress[1].toPorts[0].ports.push({port:'10080',protocol:'TCP'});}),'endpoints');
 assert.equal(variant(p=>{p.spec.egress[0].toPorts[0].ports.push({port:'5353',protocol:'UDP'});}),'endpoints');
 assert.equal(variant(p=>{p.spec.egress[1].toPorts[0].serverNames=['*.laboratory.casa'];}),'endpoints');
 assert.equal(variant(p=>{p.spec.egress[3].toFQDNs.push({matchPattern:'*'});}),'fqdn');
 assert.equal(variant(p=>{p.spec.egress[3].toFQDNs.push({matchPattern:'**.com'});}),'fqdn');
 assert.equal(variant(p=>{p.spec.egress[3].toFQDNs.push({matchPattern:'*example.org'});}),'fqdn');
 assert.equal(variant(p=>{p.spec.egress[3].toPorts[0].ports.push({port:'22',protocol:'TCP'});}),'fqdn');
 assert.equal(variant(p=>{p.spec.egress[2].toPorts[0].ports[0].endPort=65535;}),'ports');
 assert.equal(variant(p=>{delete p.spec.egress[2].toPorts[0].ports[0].protocol;}),'ports');
 assert.equal(variant(p=>{p.spec.egress[2].toPorts[0].rules={http:[{}]};}),'ports');
});
test('Guildhall may delete only its own egress policies',()=>{
 assert.equal(deleteAllowed(guildhallPolicy),true);
 assert.equal(deleteAllowed({metadata:{name:'guildhall-host-egress-ingress',labels:{}}}),false);
 assert.equal(deleteAllowed({metadata:{name:`guildhall-egress-${launch}`,labels:{'guildhall/launch-id':launch}}}),false,'unmanaged policies with a matching name stay');
});
test('Guildhall may manage only CiliumNetworkPolicies in the worker namespace, with apply verbs',()=>{
 assert.match(access,/kind: Role\n/);assert.doesNotMatch(access,/kind: ClusterRole/);
 assert.match(access,/- apiGroups: \[cilium\.io\]\n\s+resources: \[ciliumnetworkpolicies\]\n\s+verbs: \[create, get, patch, delete\]/);
 assert.doesNotMatch(access,/ciliumclusterwidenetworkpolicies|verbs: \[.*(\*|escalate|bind|list|watch|update).*\]/);
});
