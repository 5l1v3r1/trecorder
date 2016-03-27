#!/usr/bin/perl

use Audio::OSS qw(:funcs :formats :caps SNDCTL_DSP_GETBLKSIZE SNDCTL_DSP_SETTRIGGER);
use IO::File;
use MP3Recorder::AudioUtils;

my $dev='/dev/sound/dsp';

my $dsp=IO::File->new();
$dsp->open($dev,'<') or die "$dev: $!";
set_fragment($dsp,20,8);

set_fmt($dsp,AFMT_S16_LE);
die "I'm a bitch, I don't like this card!" unless set_fmt($dsp,AFMT_QUERY)==AFMT_S16_LE;
die "I'm a bitch, I don't like this card!" unless set_stereo($dsp,0)==0;
my $sr=set_sps($dsp,44100);
print "Sample rate is $sr\n";

my $bsize=get_blocksize($dsp);
my ($frags,$fragstotal,$fragsize,$avail)=get_inbuf_info($dsp);
print "bsize: $bsize, fragments: $fragstotal, fragment size: $fragsize\n";

my $data;
while (1) {
    sysread($dsp,$data,$bsize);
#    print length($data),$/;
    my $signal=MP3Recorder::AudioUtils::sound_energy_S16_mono(\$data);
    printf ("Signal: %0.2f dB\n",$signal);
}

sub get_blocksize {
    my $fh = shift;
    my $in = 0;
    my $out = pack "L", $in;
    ioctl($fh, SNDCTL_DSP_GETBLKSIZE, $out) or return undef;
    return unpack "L", $out;
}
