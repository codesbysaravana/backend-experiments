const {Queue}=require('bullmq');const fs=require('fs');const {startRedis,conn,sleep,OUT,RS}=require('./common');
const C={aof_everysec:['--appendonly','yes','--appendfsync','everysec'],aof_always:['--appendonly','yes','--appendfsync','always'],rdb_default_save:['--save','3600 1 300 100 60 10000'],no_persistence:[]};
const N=200;
(async()=>{const out=[];let k=0;
for(const [nm,args] of Object.entries(C))for(const delay of [0,2000])for(let t=1;t<=5;t++){k++;const port=6500+(k%50),dir=`${OUT}/s2_${nm}_${delay}_${t}`;
 try{let rp=await startRedis(port,dir+'/redis',args);const q=new Queue('q',{connection:conn(port)});
 for(let i=0;i<N;i++)await q.add('job',{i},{jobId:'j'+i});
 const before=await q.getJobCounts('waiting');
 await sleep(delay);rp.kill('SIGKILL');await sleep(300);await q.close();
 // restart on same dir without wiping
 const {spawn}=require('child_process');rp=spawn(RS,['--port',String(port),'--dir',dir+'/redis','--save','','--appendonly',args.includes('yes')?'yes':'no',...(args.includes('--appendfsync')?['--appendfsync',args[args.indexOf('--appendfsync')+1]]:[]),...(nm==='rdb_default_save'?['--save','3600 1 300 100 60 10000']:[])],{stdio:'ignore'});
 let q2,after;for(let i=0;i<100;i++){try{q2=new Queue('q',{connection:conn(port)});after=await q2.getJobCounts('waiting');break;}catch(e){await sleep(100);}}
 const r={config:nm,kill_after_ms:delay,trial:t,enqueued:N,waiting_before_kill:before.waiting,waiting_after_restart:after.waiting,lost:N-after.waiting};
 out.push(r);console.log(JSON.stringify(r));await q2.close();rp.kill('SIGKILL');await sleep(200);}catch(e){console.log('HARNESS_FAIL',nm,delay,t,e.message);out.push({config:nm,kill_after_ms:delay,trial:t,harness_failure:e.message});}
 fs.writeFileSync(OUT+'/s2.json',JSON.stringify(out,null,1));}
process.exit(0);})();
