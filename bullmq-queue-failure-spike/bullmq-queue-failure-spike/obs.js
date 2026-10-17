// Runs one trial of each scenario with live metrics. Metrics come from THIS orchestrator process, derived from
// durable evidence (start log, effect log/Redis list, BullMQ job counts), so killing workers never resets them.
const http=require('http');const client=require('prom-client');const {trial}=require('./s3');const {sleep}=require('./common');
const reg=new client.Registry();const L=['variant'];
const g=(n,h)=>new client.Gauge({name:n,help:h,labelNames:L,registers:[reg]});
const M={starts:g('spike_attempts_started','Processor starts (attempts incl. re-runs), from start log'),restarted:g('spike_jobs_started_more_than_once','Jobs whose processor started more than once'),dupEff:g('spike_jobs_with_duplicate_effect','Jobs whose effect was written more than once'),missing:g('spike_jobs_started_without_effect','Jobs started but with no effect written (transient while in flight; final value is the result)'),completed:g('spike_jobs_completed','BullMQ completed set size'),failed:g('spike_jobs_failed','BullMQ failed set size'),pending:g('spike_jobs_waiting_or_active','BullMQ waiting plus active'),recovery:g('spike_recovery_seconds','Seconds from worker kill until completed+failed equals jobs')};
const kills=new client.Counter({name:'spike_worker_kills_total',help:'SIGKILLs sent to workers by the harness',labelNames:L,registers:[reg]});
http.createServer(async(q,s)=>{s.setHeader('Content-Type',reg.contentType);s.end(await reg.metrics());}).listen(9101);
const hook=e=>{if(e.kill){kills.inc({variant:e.variant});return;}const l={variant:e.variant};M.starts.set(l,e.starts);M.restarted.set(l,e.restarted);M.dupEff.set(l,e.dupEff);M.missing.set(l,e.missing);M.completed.set(l,e.completed);M.failed.set(l,e.failed);M.pending.set(l,e.pending);if(e.recovery!==undefined)M.recovery.set(l,e.recovery);};
(async()=>{await sleep(8000);
 for(const [nm,ms,gd,m] of [['A_no_guard',1,'0','crash'],['C_maxStalled0',0,'0','crash'],['E_nonatomic_guard',1,'0','guardwin'],['F_atomic_guard_and_effect',1,'0','txn']]){const r=await trial(nm,ms,gd,m,30,1,hook,6800);console.log(JSON.stringify(r));await sleep(5000);}
 console.log('DONE; metrics stay up');setTimeout(()=>process.exit(0),1500000);})();
