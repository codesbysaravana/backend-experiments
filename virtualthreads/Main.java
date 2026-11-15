import java.util.concurrent.*;
import java.lang.*;

public class Main {
    public static void main(String[] args) {
        int i = 0;
        while(true) { //unbounded loopy
            Thread t1 = new Thread(() -> {
                try {
                    Thread.sleep(10 * 60 * 1000);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            });
            
            try {
                t1.start();
            } catch (OutOfMemoryError e) {
                System.out.println(e);
                System.out.println("The Death count: " + i);
                System.exit(1);
            }
            
            i++;
            if(i%100 == 0) {
                System.out.println(i);
            }
        }
    }   
}