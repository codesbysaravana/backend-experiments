const {Queue}=require('bullmq');const {spawn}=require('child_process');const fs=require('fs');const {startRedis,conn,sleep,OUT,RS}=require('./common');
const LOCK=3000,STALL=1000;
const lines=f=>fs.existsSync(f)?fs.readFileSync(f,'utf8').split('\n').filter(Boolean):[];
const dup=a=>{const m={};a.forEach(x=>m[x]=(m[x]||0)+1);return Object.values(m).filter(v=>v>1).length};
async function trial(name,maxS,guard,mode,n,t){
 const port=6400+t,dir=`${OUT}/${name}_${t}`;const rp=await startRedis(port,dir+'/redis');
 const q=new Queue('q',{connection:conn(port)});
 for(let i=0;i<n;i++)await q.add('job',{i},{jobId:'j'+i});
 const mk=(c)=>spawn('node',['worker.js',port,'q',LOCK,STALL,maxS,guard,dir,mode],{stdio:'ignore'});
 let tKill,t0=Date.now(),w1=mk(),w2;
 if(mode==='block'){await sleep(1000);w2=mk();}
 else{while(lines(dir+'/starts.log').length<5)await sleep(50);tKill=Date.now();w1.kill('SIGKILL');await sleep(500);w2=mk();}
 const tStart=tKill||t0;let state;
 for(let i=0;i<1800;i++){const c=await q.getJobCounts('completed','failed','waiting','active','delayed');if(c.completed+c.failed===n&&c.active===0){state=c;break;}await sleep(100);state=c;}
 if(mode==='block')await sleep(5000);const done=Date.now();
 const starts=lines(dir+'/starts.log'),effs=lines(dir+'/effects.log');
 const r={variant:name,trial:t,jobs:n,completed:state.completed,failed:state.failed,still_waiting_or_active:state.waiting+state.active,jobs_started_more_than_once:dup(starts),jobs_with_duplicate_effect:dup(effs),jobs_with_no_effect:n-new Set(effs).size,seconds_to_all_terminal:+((done-tStart)/1000).toFixed(1),events:lines(dir+'/events.log').slice(0,6).join(' | ').slice(0,200)};
 w1.kill('SIGKILL');w2&&w2.kill('SIGKILL');await q.close();rp.kill('SIGKILL');await sleep(300);return r;}
(async()=>{const out=[];const V=process.env.ONLY_D?[]:[['A_noguard_maxStalled1',1,'0','crash',30],['B_guard_maxStalled1',1,'1','crash',30],['C_noguard_maxStalled0',0,'0','crash',30]];V.push(['D_blocked_event_loop_1job',1,'0','block',1]);
 for(const [nm,ms,g,m,n] of V){for(let t=1;t<=5;t++){try{const r=await trial(nm,ms,g,m,n,t);out.push(r);console.log(JSON.stringify(r));fs.writeFileSync(OUT+'/s1.json',JSON.stringify(out,null,1));}catch(e){console.log('HARNESS_FAIL',nm,t,e.message);out.push({variant:nm,trial:t,harness_failure:e.message});}}}
 process.exit(0);})();
