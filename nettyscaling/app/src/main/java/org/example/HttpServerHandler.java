package org.example;

import io.micrometer.core.instrument.Counter;
import io.micrometer.prometheusmetrics.PrometheusConfig;
import io.micrometer.prometheusmetrics.PrometheusMeterRegistry;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.SimpleChannelInboundHandler;
import io.netty.handler.codec.http.DefaultFullHttpResponse;
import io.netty.handler.codec.http.HttpHeaderNames;
import io.netty.handler.codec.http.HttpHeaderValues;
import io.netty.handler.codec.http.HttpObject;
import io.netty.handler.codec.http.HttpRequest;
import io.netty.handler.codec.http.HttpResponseStatus;
import io.netty.handler.codec.http.HttpVersion;

class HttpServerHandler extends SimpleChannelInboundHandler<HttpObject> {

    private static final byte[] body = "Welcome to RPS marking system".getBytes();
    private static final PrometheusMeterRegistry registry = new PrometheusMeterRegistry(PrometheusConfig.DEFAULT);
    private static final Counter requestCounter = registry.counter("http_requests_total");

    @Override
    protected void channelRead0(ChannelHandlerContext ctx, HttpObject msg) {
        if (msg instanceof HttpRequest) {

            HttpRequest castedMessage = (HttpRequest) msg;
            requestCounter.increment();
            if (castedMessage.uri().equals("/metrics")) {
                byte[] metricsBody = registry.scrape().getBytes();

                DefaultFullHttpResponse responseForURI = new DefaultFullHttpResponse(
                        HttpVersion.HTTP_1_1,
                        HttpResponseStatus.OK,
                        ctx.alloc().buffer().writeBytes(metricsBody)
                );

                responseForURI.headers().set(HttpHeaderNames.CONTENT_LENGTH, metricsBody.length);
                responseForURI.headers().set(HttpHeaderNames.CONTENT_TYPE, "text/plain; version=0.0.4; charset=utf-8"); //since prometheus needs content headers
                responseForURI.headers().set(HttpHeaderNames.CONNECTION, HttpHeaderValues.KEEP_ALIVE);
                ctx.writeAndFlush(responseForURI);
                return;
            }

            DefaultFullHttpResponse response = new DefaultFullHttpResponse(
                    HttpVersion.HTTP_1_1,
                    HttpResponseStatus.OK,
                    ctx.alloc().buffer().writeBytes(body)
            );
            response.headers().set(HttpHeaderNames.CONTENT_LENGTH, body.length);
            response.headers().set(HttpHeaderNames.CONNECTION, HttpHeaderValues.KEEP_ALIVE);
            ctx.writeAndFlush(response);
        }
    }
}

//Why HttpObject not HttpRequest? A single HTTP request can arrive in multiple chunks. HttpObject covers both the request headers and body chunks. For now it doesn't matter, but it's the correct type.
