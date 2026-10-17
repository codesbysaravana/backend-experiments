// Scenarios E and F (guard windows) and shared trial() with optional metrics hook.
const {Queue}=require('bullmq');const {spawn}=require('child_process');const fs=require('fs');const {startRedis,conn,sleep,OUT,RS}=require('./common');
const LOCK=3000,STALL=1000;
const lines=f=>fs.existsSync(f)?fs.readFileSync(f,'utf8').split('\n').filter(Boolean):[];
const dup=a=>{const m={};a.forEach(x=>m[x]=(m[x]||0)+1);return Object.values(m).filter(v=>v>1).length};
async function trial(name,maxS,guard,mode,n,t,hook,portBase=6600){
 const port=portBase+t,dir=`${OUT}/${name}_${t}`;const rp=await startRedis(port,dir+'/redis');
 const q=new Queue('q',{connection:conn(port)});const rc=conn(port);
 for(let i=0;i<n;i++)await q.add('job',{i},{jobId:'j'+i});
 const mk=()=>spawn('node',['worker.js',port,'q',LOCK,STALL,maxS,guard,dir,mode],{stdio:'ignore'});
 const effects=async()=>mode==='txn'?await rc.lrange('effects:q',0,-1):lines(dir+'/effects.log');
 const tick=async(extra={})=>{if(!hook)return;const c=await q.getJobCounts('completed','failed','waiting','active');const s=lines(dir+'/starts.log'),e=await effects();hook({variant:name,jobs:n,starts:s.length,restarted:dup(s),dupEff:dup(e),missing:Math.max(0,s.length?new Set(s).size-new Set(e).size:0),completed:c.completed,failed:c.failed,pending:c.waiting+c.active,...extra});};
 let w1=mk(),w2;
 while(lines(dir+'/starts.log').length<5)await sleep(50);
 const tKill=Date.now();w1.kill('SIGKILL');hook&&hook({kill:1,variant:name});await sleep(500);w2=mk();
 let state;for(let i=0;i<1800;i++){const c=await q.getJobCounts('completed','failed','waiting','active');state=c;await tick();if(c.completed+c.failed===n&&c.active===0)break;await sleep(200);}
 const done=Date.now();const starts=lines(dir+'/starts.log'),effs=await effects();
 const r={variant:name,trial:t,jobs:n,completed:state.completed,failed:state.failed,still_waiting_or_active:state.waiting+state.active,jobs_started_more_than_once:dup(starts),jobs_with_duplicate_effect:dup(effs),jobs_with_no_effect:n-new Set(effs).size,seconds_to_all_terminal:+((done-tKill)/1000).toFixed(1)};
 await tick({recovery:r.seconds_to_all_terminal});
 w1.kill('SIGKILL');w2&&w2.kill('SIGKILL');await q.close();rc.disconnect();rp.kill('SIGKILL');await sleep(300);return r;}
module.exports={trial};
if(require.main===module)(async()=>{const out=[];
 for(const [nm,ms,g,m,n] of [['E_nonatomic_guard_crash_between_guard_and_effect',1,'0','guardwin',30],['F_atomic_guard_plus_effect_in_redis_lua',1,'0','txn',30]])for(let t=1;t<=5;t++){try{const r=await trial(nm,ms,g,m,n,t);out.push(r);console.log(JSON.stringify(r));}catch(e){console.log('HARNESS_FAIL',nm,t,e.message);out.push({variant:nm,trial:t,harness_failure:e.message});}fs.writeFileSync(OUT+'/s3.json',JSON.stringify(out,null,1));}
 process.exit(0);})();
