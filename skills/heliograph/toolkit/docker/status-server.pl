#!/usr/bin/perl
# =============================================================================
#  status-server.pl - answer "is the agent alive, and what is it doing?"
# =============================================================================
#  heliograph's weakest point is that the far side is opaque. You push a
#  request and wait, and "running for forty minutes" looks the same as "died an
#  hour ago". agent.sh already writes agent/status on every transition. This
#  serves it.
#
#  It exists for two reasons at once:
#
#  1. Azure Web App for Containers runs a startup probe on a port and cannot be
#     told not to. A container that never listens is killed after 230 seconds
#     and the site is stopped. Measured, not guessed. Without something
#     listening, that host cannot run this workload at all.
#
#  2. A status endpoint is worth having anyway, on any host. Point a monitor at
#     /health and you get told when the loop stops, instead of finding out when
#     a log you were waiting for never arrives.
#
#  PERL, NOT PYTHON OR BUSYBOX, because perl is already in the image. git pulls
#  it in, about 21MB of it, and IO::Socket::INET is core. Adding python3-minimal
#  or busybox for this would be adding a package to use something already there.
#
#  IT SERVES STATUS, NOT LOGS. The logs go back over git, which is the whole
#  design, and an unauthenticated HTTP endpoint on a container in someone's
#  estate is the wrong place for captured output. It reports what the agent is
#  doing, never what a step found.
#
#  READ ONLY, NO SHELL. It takes no input beyond the request path, matches that
#  path against a fixed list, and never passes any of it to a shell or a file
#  open. Anything unrecognised is a 404.
# =============================================================================
use strict;
use warnings;
use IO::Socket::INET;

my $port    = $ENV{HELIOGRAPH_STATUS_PORT} || 8080;
my $workdir = $ENV{HELIOGRAPH_WORKDIR}     || "$ENV{HOME}/repo";

# Reap the agent's children if we ever end up as pid 1.
$SIG{CHLD} = 'IGNORE';
$SIG{PIPE} = 'IGNORE';

my $sock = IO::Socket::INET->new(
    LocalPort => $port,
    Listen    => 16,
    ReuseAddr => 1,
    Proto     => 'tcp',
) or die "status-server: cannot listen on $port: $!\n";

print "status-server: listening on $port, reporting on $workdir\n";

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub reply {
    my ($client, $code, $type, $body) = @_;
    $body = '' unless defined $body;
    print $client "HTTP/1.1 $code\r\n",
                  "Content-Type: $type\r\n",
                  "Content-Length: " . length($body) . "\r\n",
                  "Connection: close\r\n\r\n",
                  $body;
}

while (my $client = $sock->accept) {
    my $req = <$client>;
    $req = '' unless defined $req;
    my ($path) = $req =~ m{^GET\s+(\S+)\s} ? ($1) : ('/');
    $path =~ s/\?.*$//;

    my $status = slurp("$workdir/agent/status");

    if ($path eq '/health' or $path eq '/') {
        # LIVENESS, and deliberately always 200 while this server is answering.
        #
        # This is what a platform startup probe asks: did the container come
        # up? If this code is running, it did. Returning 503 here because the
        # agent has not written a status yet would fail the probe and get the
        # site stopped, which is the exact failure this server exists to
        # prevent. Found by making that mistake first.
        #
        # Whether the AGENT is healthy is a different question, and /status
        # answers it. Point a monitor there, not here.
        my $agent = defined $status ? "running" : "no status file yet";
        reply($client, '200 OK', 'text/plain',
              "container: up\nagent:     $agent\n\nGET /status for the agent's own report.\n");
    } elsif ($path eq '/status') {
        if (defined $status) {
            reply($client, '200 OK', 'text/plain', $status);
        } else {
            reply($client, '503 Service Unavailable', 'text/plain',
                  "no agent/status yet\n\nThe container is up and this server is answering, so the\n" .
                  "image and the port are fine. The agent has not written a status\n" .
                  "yet, which usually means the clone or the preflight is still\n" .
                  "running, or start.sh refused. Check the container log.\n");
        }
    } else {
        reply($client, '404 Not Found', 'text/plain', "try /, /health or /status\n");
    }
    close $client;
}
