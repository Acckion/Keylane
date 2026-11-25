#!/usr/bin/env python3
"""Aggregate explicit restricted-JSC M0 feasibility evidence. Never enables runtime."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent.parent
MODULES={
    'restricted':('verify-macos-restricted-js-m0.py','restricted-final.json','REQUIRED_CASES'),
    'broker':('verify-macos-broker-m0.py','broker-final.json','CASES'),
    'receipt':('verify-macos-receipt-m0.py','receipt-final.json','CASES'),
    'transport':('verify-macos-transport-m0.py','transport-final.json','CASES'),
    'trust':('verify-macos-trust-m0.py','trust-final.json','CASES'),
    'boundary':('verify-macos-boundary-m0.py','boundary-final.json','CASES'),
    'privacy':('verify-macos-privacy-m0.py','privacy-final.json','CASES'),
    'compatibility':('verify-macos-compatibility-m0.py','compatibility-final.json','CASES')
}


def required_cases(script,attribute):
    spec=importlib.util.spec_from_file_location('m0_gate_'+script.replace('-','_'),ROOT/'scripts'/script)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return getattr(module,attribute)


def assess(decision,evidence):
    if decision.get('engine')!='restricted-JavaScriptCore' or decision.get('strictIsolation') is not True or decision.get('vmAllowed') is not False or decision.get('compatibility')!='explicit-subset':
        raise ValueError('Missing explicit restricted-engine decision')
    failures=[];checks=0
    for name,(script,_,attribute)in MODULES.items():
        record=evidence.get(name)
        if not isinstance(record,dict):raise ValueError('Missing evidence: '+name)
        if record.get('fixtureOnly') is not True or record.get('installed') is not False:
            raise ValueError('Invalid fixture scope: '+name)
        cases=record.get('cases',{})
        for key in required_cases(script,attribute):
            if type(cases.get(key))is not bool:raise ValueError('Missing/non-boolean observation: '+name+'.'+key)
            checks+=1
            if not cases[key]:failures.append(name+'.'+key)
        for flag in ['signaturesVerifiedBeforeAndAfter','temporaryArtifactsRemoved']:
            if record.get(flag) is not True:raise ValueError('Unverified '+name+'.'+flag)
        if record.get('gate') not in ('incomplete','blocked'):raise ValueError('Unexpected subset gate')
        if record.get('gate')=='blocked' and not any(item.startswith(name+'.')for item in failures):
            failures.append(name+'.subset-blocked')
    return {'schema':1,'scope':'first-party-restricted-JSC-feasibility',
            'gate':'blocked'if failures else'feasibility-passed','failures':sorted(failures),
            'checks':checks,'productionRuntimeReady':False,'publicExtensionsVerified':False,
            'M1Started':False,'candidate':'restricted-JavaScriptCore',
            'limitations':['No Node-equivalence claim','No native-code or engine-vulnerability containment proof',
                           'Sampling is not a hard memory ceiling','No whole-container wipe claim',
                           'Product enrollment and deployment remain M1-M5 work']}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence',type=Path,default=ROOT/'docs/evidence/macos-runtime-m0/final')
    parser.add_argument('--report',type=Path,required=True);args=parser.parse_args()
    if args.report.exists():raise SystemExit('Refusing report overwrite')
    decision=json.loads((args.evidence.parent/'engine-decision.json').read_text())
    inputs={};hashes={}
    for name,(_,file,_)in MODULES.items():
        body=(args.evidence/file).read_bytes();inputs[name]=json.loads(body)
        hashes[file]=hashlib.sha256(body).hexdigest()
    report=assess(decision,inputs);report['evidenceSHA256']=hashes
    # Old Node failure evidence remains visible and is never recast as JSC success.
    for file in ['node-rejected.json','slots-rejected.json']:
        record=json.loads((args.evidence/file).read_text())
        if record.get('gate')!='blocked':raise ValueError('Rejected alternative evidence changed')
    report['rejectedAlternative']='full-Node-App-Sandbox: blocked'
    args.report.parent.mkdir(parents=True,exist_ok=True)
    with args.report.open('x')as file:json.dump(report,file,indent=2)
    print(json.dumps({'gate':report['gate'],'productionRuntimeReady':False,'report':str(args.report)}))
    return 0 if report['gate']=='feasibility-passed'else 2


if __name__=='__main__':raise SystemExit(main())
