FROM ocaml/opam2:alpine-3.9-ocaml-4.07 as BUILD

RUN sudo apk --no-cache add --update \
    alpine-sdk \
    autoconf \
    bash \
    gmp-dev \
    linux-headers \
    perl

RUN opam install -y dune

ARG DATABOX_ORG=me-box
RUN opam pin add -n mirage-net-psock \
    https://github.com/$DATABOX_ORG/mirage-net-psock.git
#    && echo "$(opam config exec -- dune external-lib-deps --missing -p mirage-net-psock @@default 2>&1 | tail -1 | cut -f3- -d' ')"

WORKDIR /core-network
ADD . .
RUN sudo chown opam: -R .

RUN opam config exec -- \
    dune external-lib-deps --missing @all 2>&1 | tail -1 | cut -f3- -d" " | sh
RUN opam config exec -- \
    dune build bin/core_network.exe

FROM alpine:3.9.3
RUN apk --no-cache add --update \
    bash \
    gmp-dev \
    iproute2 \
    iptables \
    tcpdump

EXPOSE 8080
LABEL databox.type="core-network"

WORKDIR /core-network
COPY --from=BUILD /core-network/_build/default/bin/core_network.exe core-network
ADD start.sh start.sh
ENTRYPOINT ["./start.sh"]
