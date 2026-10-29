# raydns

Descubrimiento de servicios por DNS, escrito en [raylang](https://github.com/ray-language/raylang).
Las instancias se registran por HTTP con un lease o un health check, y raydns las sirve como DNS
autoritativo de una zona: `api.service.ray.internal` resuelve a las instancias sanas de `api`, y
`_api._tcp.service.ray.internal` da sus SRV con puerto. Cualquier cliente DNS (`dig`, el resolver
del sistema, `net/dns`) sirve; quien quiera seguir los cambios al momento usa la consulta
bloqueante del API.

```
$ raydns serve
raydns 0.1.0: dns udp+tcp 127.0.0.1:8600 for ray.internal, api http://127.0.0.1:8500, 2 receivers, ttl 5s, 3 static record(s)

$ raydns register --ttl 10s --tag v2 --http-check http://10.0.0.5:8080/health api a1 10.0.0.5:8080
raydns: api/a1 at 10.0.0.5:8080 registered; renewing every 3333 ms

$ dig @127.0.0.1 -p 8600 +short api.service.ray.internal
10.0.0.5
$ dig @127.0.0.1 -p 8600 +short _api._tcp.service.ray.internal SRV
1 1 8080 a1.api.instance.ray.internal.
```

```
raydns serve [--config raydns.toml]
raydns register [--api URL] [--token T] [--ttl 10s] [--tag T]... [--http-check URL | --tcp-check HOST:PORT] SERVICE ID ADDRESS:PORT
raydns ls [--api URL] [SERVICE]
raydns bench HOST:PORT NAME [-n QUERIES] [-c CLIENTS] [--type A|SRV|AAAA]
```

`register` hace de acompañante para una app que no habla con raydns: registra, renueva el lease cada
tercio del TTL (y registra de nuevo si raydns lo perdió) y da de baja al recibir SIGINT/SIGTERM.

## Estado

| Qué | Estado |
|---|---|
| Registro por HTTP: alta, renovación, baja, listado, filtro `passing` | ✅ |
| Leases (TTL): sin renovar, la instancia pasa a crítica y sale del DNS | ✅ |
| Health checks activos HTTP (2xx) y TCP (connect), una fibra por instancia | ✅ (TCP probado en tests, HTTP solo a mano) |
| Baja automática tras `deregister_after` en estado crítico | ✅ |
| Consulta bloqueante: `?index=N&wait=30s` vuelve cuando el servicio cambia | ✅ |
| DNS: A/AAAA por servicio y por tag, SRV con direcciones en ADDITIONAL, nombre por instancia | ✅ |
| DNS: registros estáticos (A, AAAA, CNAME seguido dentro de la zona, TXT, MX), SOA, NS | ✅ |
| NXDOMAIN frente a NODATA (servicio conocido sin nadie sano), SOA en AUTHORITY, REFUSED fuera de la zona | ✅ |
| EDNS0 (1232), truncado con TC y TCP en el mismo puerto (RFC 7766, varios mensajes por conexión) | ✅ |
| Persistencia del registro (JSON reemplazado de forma atómica) | ✅ |
| Token bearer para escribir en el API | ✅ |
| Integración en raygate y raylb (backends desde raydns) | ➖ v2 |
| Varios nodos raydns replicados, DNSSEC, AXFR, PTR | ➖ v2 |

Pruebas: 12 tests (`make test`, `make test-native`), en VM y nativo; y `make interop`, que pasa 20
comprobaciones con `dig` contra el binario.

## Cómo

```
src/main.ray      la línea de órdenes (serve, register, ls, bench)
src/config.ray    raydns.toml: direcciones, zona, TTL, registros estáticos
src/server.ray    todo junto: registro, DNS por UDP y TCP, API
src/registry.ray  el registro: una fibra dueña de las instancias, leases, índices, vistas
src/checks.ray    los health checks, una fibra por instancia
src/api.ray       el API HTTP (JSON)
src/dnsd.ray      las receptoras UDP y las conexiones TCP
src/zone.ray      la respuesta a una pregunta (puro)
src/wire.ray      el formato de DNS: leer preguntas, escribir respuestas comprimidas
src/bench.ray     el generador de carga
```

- **Una fibra es dueña del registro.** El API le pregunta por un canal; cada cambio (alta, baja, una
  instancia que pasa a sana o a crítica) sube un índice global y el del servicio. Renovar un lease
  no es un cambio, y registrar lo mismo otra vez es una renovación.
- **Las receptoras DNS nunca preguntan.** Cada una se suscribe y el registro le empuja una `View`
  (las instancias sanas y los nombres de servicio) tras cada cambio. La receptora toma la más nueva
  después de que llegue el datagrama, no antes: el primer intento la tomaba antes de esperar y
  respondía con la vista de hasta 200 ms atrás. Una conexión TCP pide una sola vista y no se
  suscribe.
- **Varias receptoras sobre el mismo socket UDP**, con un plazo de lectura de 200 ms para ver la
  orden de parar.
- **El orden de las respuestas cambia en cada consulta** (shuffle), para repartir los clientes.
- **El estado se guarda** como JSON: se escribe en `.tmp`, se hace `fsync` y se renombra. Como mucho,
  una vez por segundo y al parar. Los leases se guardan con su hora absoluta: al volver, lo que
  caducó mientras tanto caduca en el primer tick.
- **Los nombres de servicio, las ids y los tags son etiquetas DNS** (`a-z`, `0-9`, `-`); el API
  rechaza el resto, así que toda instancia tiene nombre en la zona.

## Rendimiento

`make bench` (scripts/bench.sh): binario nativo con raylang 1.27.85 en un MacBook (Apple Silicon,
11 núcleos), un servicio de 3 instancias, `raydns bench` desde otro proceso en bucle cerrado:

| receptoras | 16 clientes | 64 clientes |
|---:|---:|---:|
| 1 | 88 k consultas/s, p99 216 µs | 88 k/s, p99 778 µs |
| 2 | **115 k/s**, p99 227 µs | **118 k/s**, p99 686 µs |
| 4 | 104 k/s, p99 237 µs | 105 k/s, p99 742 µs |
| 8 | 84 k/s, p99 324 µs | 84 k/s, p99 916 µs |

Sin una sola consulta perdida, con 10–11 MiB de RSS. El techo está en el servidor (con más clientes
solo sube la latencia), y más de 2 receptoras sobre el mismo socket rinden menos, como avisa
`llms.txt` para servidores con pocas conexiones por worker.

## Hallazgos de dogfood

En `../findings/open/raydns-1.27.85.md`. Re-medido con 1.27.86 y net 0.13.0: #286 y #288 arreglados; #287 sigue.

Lo que se encontró con 1.27.85:

- **#286 [B] net**: `dns.query_a` devuelve el destino de un CNAME mezclado con las direcciones.
- **#287 [E] net**: `net/dns` solo es cliente; raydns trae su `wire.ray` (preguntas, respuestas con
  compresión, EDNS, truncado), probado en los dos sentidos contra `net/dns` y contra `dig`.
- **#288 [D]**: `std/toml` no acepta claves entre comillas en una cabecera de tabla, y su doc dice que
  admite claves con comillas. De ahí `[[record]]` con `name`.

Lo que salió bien: los 12 tests pasaron en nativo a la primera; `net/udp` con varias receptoras en
un socket, `select_timeout` para los checks y `try_recv` para tomar la última vista compusieron sin
fricción; y `dig` dio por bueno el formato desde la primera respuesta.
