// Redis restart with an explicit RDB snapshot baseline, to separate "persistence configured" from "snapshot actually exists".
const {Queue}=require('bullmq');const {spawn}=require('child_process');const fs=require('fs');const {startRedis,conn,sleep,OUT,RS}=require('./common');
const RSB=RS;const N=200;const rules=['--save','3600 1 300 100 60 10000'];
(async()=>{const out=[];
for(const [nm,snapAfter] of [['rdb_default_save_SAVE_after_all_200',200],['rdb_default_save_SAVE_after_first_100',100],['rdb_default_save_no_SAVE',0]])for(let t=1;t<=5;t++){const port=6700+t,dir=`${OUT}/s2b_${nm}_${t}`;
 try{let rp=await startRedis(port,dir+'/redis',rules);const q=new Queue('q',{connection:conn(port)});const rc=conn(port);
 for(let i=0;i<N;i++){await q.add('job',{i},{jobId:'j'+i});if(snapAfter&&i+1===snapAfter)await rc.save();}
 const info=await rc.info('persistence');const g=k=>(info.match(new RegExp(k+':(\\S+)'))||[])[1];
 const meta={rdb_last_save_time_unix:g('rdb_last_save_time'),rdb_changes_since_last_save:g('rdb_changes_since_last_save'),rdb_last_bgsave_status:g('rdb_last_bgsave_status'),rdb_file_exists_before_kill:fs.existsSync(dir+'/redis/dump.rdb')};
 rp.kill('SIGKILL');await sleep(300);await q.close();rc.disconnect();
 rp=spawn(RSB,['--port',String(port),'--dir',dir+'/redis','--appendonly','no',...rules],{stdio:'ignore'});
 const q2=new Queue('q',{connection:conn(port)});const after=await q2.getJobCounts('waiting');
 const r={config:nm,trial:t,enqueued:N,...meta,waiting_after_restart:after.waiting,lost:N-after.waiting};out.push(r);console.log(JSON.stringify(r));await q2.close();rp.kill('SIGKILL');await sleep(200);}catch(e){console.log('HARNESS_FAIL',nm,t,e.message);out.push({config:nm,trial:t,harness_failure:e.message});}
 fs.writeFileSync(OUT+'/s2b.json',JSON.stringify(out,null,1));}
process.exit(0);})();
