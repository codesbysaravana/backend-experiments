const {Worker}=require('bullmq');const fs=require('fs');const {conn,sleep}=require('./common');
const [port,q,lock,stall,maxS,guard,dir,mode]=process.argv.slice(2);
const eff=conn(Number(port));eff.select&&0;
const w=new Worker(q,async job=>{
 fs.appendFileSync(dir+'/starts.log',job.id+'\n');
 if(mode==='guardwin'){const n=await eff.sadd('eff:'+q,job.id);await sleep(1500);if(n===1)fs.appendFileSync(dir+'/effects.log',job.id+'\n');await sleep(300);return 'ok';}
 if(mode==='txn'){await eff.eval("if redis.call('SADD',KEYS[1],ARGV[1])==1 then redis.call('RPUSH',KEYS[2],ARGV[1]) end return 1",2,'eff:'+q,'effects:'+q,job.id);await sleep(1500);return 'ok';}
 if(mode==='block'){ if(job.attemptsStarted===1){const e=Date.now()+6000;while(Date.now()<e){} fs.appendFileSync(dir+'/effects.log',job.id+'\n');return 'ok';} fs.appendFileSync(dir+'/effects.log',job.id+'\n');await sleep(200);return 'ok';}
 if(guard==='1'){const n=await eff.sadd('eff:'+q,job.id); if(n===1) fs.appendFileSync(dir+'/effects.log',job.id+'\n');}
 else fs.appendFileSync(dir+'/effects.log',job.id+'\n');
 await sleep(1500);return 'ok';
},{connection:conn(Number(port)),concurrency:mode==='block'?1:5,lockDuration:Number(lock),stalledInterval:Number(stall),maxStalledCount:Number(maxS)});
w.on('error',e=>fs.appendFileSync(dir+'/events.log','error '+e.message+'\n'));
w.on('failed',(j,e)=>fs.appendFileSync(dir+'/events.log','failed '+(j&&j.id)+' '+e.message+'\n'));
w.on('stalled',id=>fs.appendFileSync(dir+'/events.log','stalled '+id+'\n'));
