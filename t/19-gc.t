use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2);

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 1;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';

our $HttpConfig = qq{
    lua_package_path "$pwd/../lua-resty-redis/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        local use_resty_core = $ENV{TEST_USE_RESTY_CORE}
        if use_resty_core then
            require 'resty.core'
        end
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
        ledge:config_set('keep_cache_for', 0)
    ";

    init_worker_by_lua "
        ledge:run_workers()
    ";
};

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Prime cache
--- http_config eval: $::HttpConfig
--- config
    location /gc_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /gc {
        more_set_headers "Cache-Control: public, max-age=60";
        echo "OK";
    }
--- request
GET /gc_prx
--- no_error_log
--- response_body
OK


=== TEST 2: Force revaldation (creates new entity)
--- http_config eval: $::HttpConfig
--- config
    location /gc_prx {
        rewrite ^(.*)_prx$ $1 break;
        echo_location_async '/gc_a';
        echo_sleep 0.05;
        echo_location_async '/gc_b';
        echo_sleep 2.5;
    }
    location /gc_a {
        rewrite ^(.*)_a$ $1 break;
        content_by_lua '
            ledge:run();
        ';
    }
    location /gc_b {
        rewrite ^(.*)_b$ $1 break;
        content_by_lua '
           local redis_mod = require "resty.redis"
           local redis = redis_mod.new()
           redis:connect("127.0.0.1", 6379)
           redis:select(ledge:config_get("redis_database"))
           local cache_key = ledge:cache_key()
           local num_entities, err = redis:zcard(cache_key .. ":entities")
           ngx.say(num_entities)
           local memused  = redis:get(cache_key .. ":memused")
           ngx.say(memused)
        ';
    }
    location /gc {
        more_set_headers "Cache-Control: public, max-age=5";
        echo "UPDATED";
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /gc_prx
--- no_error_log
--- response_body
UPDATED
2
11


=== TEST 3: Check we now have just one entity, and memused is reduced by 3 bytes.
--- http_config eval: $::HttpConfig
--- config
    location /gc {
        content_by_lua '
            ngx.sleep(1) -- Wait for qless to do the work

           local redis_mod = require "resty.redis"
           local redis = redis_mod.new()
           redis:connect("127.0.0.1", 6379)
           redis:select(ledge:config_get("redis_database"))
           local cache_key = ledge:cache_key()
           local num_entities, err = redis:zcard(cache_key .. ":entities")
           ngx.say(num_entities)
           local memused  = redis:get(cache_key .. ":memused")
           ngx.say(memused)
        ';
    }
--- request
GET /gc
--- no_error_log
--- response_body
1
8


=== TEST 4: Entity will have expired, check everything is still ok
--- http_config eval: $::HttpConfig
--- config
    location /gc_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ngx.sleep(4)
            ledge:run()
        ';
    }
    location /gc {
        more_set_headers "Cache-Control: public, max-age=60";
        echo "OK";
    }
--- request
GET /gc_prx
--- timeout: 6
--- no_error_log
--- response_body
OK
