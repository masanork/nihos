#!/usr/bin/env python3
"""Qualify automatic card metadata. Optical evidence is separate; no values accepted."""
import argparse
import importlib.util
import json
from pathlib import Path
SPEC=importlib.util.spec_from_file_location('auto_display',Path(__file__).with_name('check-native-display-log.py'))
DISPLAY=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(DISPLAY)
NATIVE=DISPLAY.NATIVE
DETECTED=('job','kind','pin1_verifies','pin2_verifies','cleanup','erased')
PROMPT=('job','kind','pin_index','pin1_remaining','pin2_remaining','pin1_verifies','pin2_verifies')
RESULT=('job','kind','state','fault','sw','pin1_verifies','pin2_verifies','fields','photo_decoded','photo_error','shown','missing','truncated','cleanup','verification','changes')
DONE=('job','kind','fault','pin1_verifies','pin2_verifies','fields','photo_decoded','shown','missing','truncated','cleanup','erased','verification','changes')
ABORT=('job','kind','state','fault','pin1_verifies','pin2_verifies')
def records(log,tag,names):return NATIVE.repeated_records(log,'NIHOS_NATIVE_CARD_AUTO_'+tag,names)
def check_auto(log,read_enabled,required=()):
    log=log.replace('\r','')
    detected=records(log,'DETECTED',DETECTED)
    removed=records(log,'REMOVED',('job',))
    selections=records(log,'SELECTED',('job','kind'))
    selected={}
    prompts=records(log,'PROMPT',PROMPT)
    results=records(log,'RESULT',RESULT)
    done=records(log,'DONE',DONE)
    aborted=records(log,'ABORT',ABORT)
    if not detected:raise ValueError('no automatic card classification')
    seen=set();cleared=set();kinds=set();classified={row['job']:row['kind'] for row in detected}
    for row in removed:
        if row['job'] in cleared:raise ValueError('duplicate removal')
        cleared.add(row['job'])
    for row in detected:
        job=row['job'];kind=row['kind']
        if job!=len(seen)+1 or kind not in (0,1,2,3,4) or row['pin1_verifies'] or row['pin2_verifies'] or row['cleanup']!=2 or row['erased']!=1:
            raise ValueError('classification is not a clean PIN-free job')
        here=log.index(f'NIHOS_NATIVE_CARD_AUTO_DETECTED job={job:08x}')
        if seen:
            old=job-1
            if old not in cleared or not log.index(f'NIHOS_NATIVE_CARD_AUTO_DETECTED job={old:08x}') < log.index(f'NIHOS_NATIVE_CARD_AUTO_REMOVED job={old:08x}') < here:
                raise ValueError('a held card was rearmed without physical removal')
        seen.add(job)
        if not read_enabled and kind in (1,2,4):kinds.add(kind)
    for row in selections:
        job=row['job'];kind=row['kind']
        if job not in seen or job in selected or kind not in ((1,4) if classified[job]==4 else (classified[job],)) or kind not in (1,2,4):raise ValueError('invalid/duplicate local profile selection')
        if log.index(f'NIHOS_NATIVE_CARD_AUTO_SELECTED job={job:08x}')<log.index(f'NIHOS_NATIVE_CARD_AUTO_DETECTED job={job:08x}'):raise ValueError('selection before detection')
        selected[job]=kind
    for row in prompts+results+done+aborted:
        if row['job'] not in seen or row['kind'] not in (1,2,4) or row['kind']!=selected.get(row['job']) or row['pin1_verifies']>1 or row['pin2_verifies']>1:
            raise ValueError('orphan job or repeated credential')
    if not cleared<=seen:raise ValueError('orphan removal')
    for job in cleared:
        if log.index(f'NIHOS_NATIVE_CARD_AUTO_REMOVED job={job:08x}') < log.index(f'NIHOS_NATIVE_CARD_AUTO_DETECTED job={job:08x}'):
            raise ValueError('removal before classification')
    if not read_enabled and (selections or prompts or results or done or aborted):raise ValueError('authenticated operation in detection-only profile')
    if aborted:raise ValueError('automatic-card job aborted')
    for row in prompts:
        index=row['pin_index']
        if row['pin1_verifies'] != (1 if index==2 else 0) or row['pin2_verifies'] or row['pin1_remaining'] not in (range(2,11) if row['kind']==4 else (2,3)) or index not in ((0,) if row['kind']==1 else (3,) if row['kind']==4 else (1,2)) or (index==2 and row['pin2_remaining'] not in (2,3)):
            raise ValueError('unsafe local PIN prompt')
    completed=set()
    for row in done:
        job=row['job'];matches=[r for r in results if r['job']==job]
        if job in completed or len(matches)!=1:raise ValueError('missing/duplicate result lifecycle')
        result=matches[0]
        job_prompts=[r for r in prompts if r['job']==job]
        if [r['pin_index'] for r in job_prompts] != ([0] if row['kind']==1 else [3] if row['kind']==4 else [1,2]):
            raise ValueError('missing/duplicate/out-of-order local PIN sessions')
        positions=[log.index(f'NIHOS_NATIVE_CARD_AUTO_DETECTED job={job:08x}'),log.index(f'NIHOS_NATIVE_CARD_AUTO_SELECTED job={job:08x}')]
        positions += [log.index('NIHOS_NATIVE_CARD_AUTO_PROMPT'+''.join(f' {key}={r[key]:08x}' for key in PROMPT)) for r in job_prompts]
        positions += [log.index(f'NIHOS_NATIVE_CARD_AUTO_RESULT job={job:08x}'),log.index(f'NIHOS_NATIVE_CARD_AUTO_DONE job={job:08x}')]
        if job in cleared:positions.append(log.index(f'NIHOS_NATIVE_CARD_AUTO_REMOVED job={job:08x}'))
        if positions!=sorted(set(positions)):raise ValueError('out-of-order automatic card lifecycle')
        fields=15 if row['kind']==1 else 7 if row['kind']==4 else 31
        if row['verification'] not in ((0,) if row['kind']==1 else (1,2)) or not 0<=row['changes']<=32 or (row['kind'] in (1,4) and row['changes']):raise ValueError('invalid signature/history state')
        if (row['fault'] or row['pin1_verifies']!=1 or (row['pin2_verifies']!=1 if row['kind']==2 else row['pin2_verifies'] not in ((0,) if row['kind']==4 else (0,1))) or
                row['fields']!=fields or row['shown']!=fields or row['photo_decoded']!=1 or row['missing'] or row['truncated'] or row['cleanup']!=2 or row['erased']!=1 or
                result['state'] or result['sw'] not in (0x9000,0x6282) or result['photo_error'] or
                any(result[key]!=row[key] for key in DONE if key not in ('erased',))):
            raise ValueError('incomplete card read / portrait / display / erasure')
        if not log.index(f'NIHOS_NATIVE_CARD_AUTO_RESULT job={job:08x}') < log.index(f'NIHOS_NATIVE_CARD_AUTO_DONE job={job:08x}'):
            raise ValueError('result cleared before display')
        completed.add(job);kinds.add(row['kind'])
    if not set(required)<=kinds:raise ValueError('required card kinds not qualified')
    if any(tag in log for tag in ('NIHOS_NATIVE_KEYPAD_EVENT ', 'NIHOS_NATIVE_TOUCH_EVENT ', 'NIHOS_NATIVE_JPKI ')):
        raise ValueError('unexpected key/identity logging')
    return {'read_enabled':read_enabled,'classified':detected,'removed':removed,'selections':selections,'prompts':prompts,'completed':done,'aborted':aborted,'qualified_kinds':sorted(kinds),'signature_verified_jobs':[r['job'] for r in done if r['verification']==2],'optical_evidence':'requires separate user observation'}
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log',type=Path);parser.add_argument('audit',type=Path);parser.add_argument('report',type=Path)
    parser.add_argument('--require-signature',action='store_true')
    parser.add_argument('--kinds',default='1,2,4',help='required kind numbers, comma separated')
    args=parser.parse_args();image=json.loads(args.audit.read_text());log=args.log.read_text()
    profile=image.get('automatic_cards')
    if not profile:raise SystemExit('not an audited automatic-card image')
    report={'display':DISPLAY.check(log,image,11,80),'automatic_cards':check_auto(log,profile['read_enabled'],[int(v) for v in args.kinds.split(',') if v])}
    completed=report['automatic_cards']['completed']
    if not profile.get('trust_bytes') and any(r['verification']==2 for r in completed):raise ValueError('signature success without a provisioned key')
    licence=[r for r in completed if r['kind']!=1]
    if args.require_signature and (not licence or any(r['verification']!=2 for r in licence)):raise ValueError('trusted signature verification not completed')
    args.report.write_text(json.dumps(report,indent=2)+'\n')
    print('Automatic card lifecycle and requested kinds passed; values excluded')
if __name__=='__main__':main()
