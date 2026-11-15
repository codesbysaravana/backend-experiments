Platform thread, one blocking call:
1. Code starts a thread
2. JVM asks the OS for a real thread - 1MB stack, one pid
3. Your code hits sleep/DB/API
4. The OS thread sits there. Waiting. Burning its 1MB, doing nothing
5. Call returns, thread wakes, finishes

Virtual thread, same blocking call:
1. Code starts a virtual thread - just a small object on the heap, ~1.3KB
2. The JVM mounts it onto a carrier (a real OS thread, one of ~2 on your box)
3. Your code hits sleep/DB/API
4. The virtual thread UNMOUNTS - hops off the carrier. The carrier immediately picks up another waiting virtual thread
5. The sleep/DB/API finishes
6. The virtual thread gets mounted back onto whichever carrier is free, and finishes