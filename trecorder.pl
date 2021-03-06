#!/usr/bin/perl
use strict;
use warnings;
no warnings 'uninitialized';

# what this will be:
#
# triggered recorder
#
# records blocks of sound to mp3, blocks are designated by silence
# no gui

# things to design:
# - should the recording child process detect silence?
# - how to pass timing info from child to main process?
# - job of the main process:
#   if it handles silence detection:
#    - receive audio data
#    - buffer audio for $prerecord time
#    - if sound is detected when not saving audio, start saving (including the prebuffered audio)
#    - if silence is detected for $silencethreshold time, stop saving
#
# some operations in detail:
#  - start saving:
#     - writes record for this point in output mp3 file into .cue file
#     - encode and write buffered audio into mp3 file
#     - change state
#
#  - stop saving:
#     - flush mp3 frame
#     - change state
#
# state variables to maintain:
#  - to save or not to save
#  - progress in output mp3 file, for writing the cue file
#  - something about input audio? (like how much of the prerecord buffer is already saved*)
#
# * when starting saving, it could happen that part of the prerecord buffer is
#   already saved as part of the previous block's trailing silence

use MP3Recorder::OSS;
use MP3Recorder::AudioUtils;
use Event;
use Event::IOExtra;
use Audio::MPEG;
use Data::Dumper;
use Time::HiRes;


my $record_config=+{
    sample_rate=>11025,
    num_channels=>1,
    bit_rate=>32,
    mp3_quality=>2,
    mp3_mode=>'mono',
    detection_period=>50,   # 50 millisec, that's the cycle time for a 20Hz sound
    prerecord=>500,         # this many milliseconds before sound is to be recorded
    threshold=>-40,         # sound level above this is considered sound (not silence)
    silence_threshold=>800, # this many milliseconds of silence stops recorging
};

our $fn;

my $recorder_pid;

# TODO command line options, arguments
start_recording('t-test.mp3','t-test.cue');

sub stop_recording {
    return unless $recorder_pid;
    kill 'SIGUSR1',$recorder_pid;
    $recorder_pid=undef;
    print STDERR "recorder process signalled\n";
}

our $mp3_enc;
our $do_exit;
my $detection_samples;
sub start_recording {
    $SIG{INT}=sub {$do_exit=1 if !$do_exit;};
    # calculate number of samples for sound detection
    # that will be the size of block for data flow between recording process and main process
    $record_config->{detection_samples}=int($record_config->{sample_rate}*$record_config->{detection_period}/1000);
    $@='';
    eval {
        my ($fn,$cuefile)=@_;
        # init mp3 encoder
        my $mp3conf=+{
            in_sample_rate=>$record_config->{sample_rate},
            in_channels=>$record_config->{num_channels},
            bit_rate=>$record_config->{bit_rate},
            write_vbr_tag=>0,
        };
        $mp3conf->{mode}=$record_config->{mp3_mode} if defined $record_config->{mp3_mode};
        $mp3conf->{quality}=$record_config->{mp3_quality} if defined $record_config->{mp3_quality};
        $mp3_enc=Audio::MPEG::Encode->new($mp3conf);
        
        # open output file
        open MP3_OUT,"> $fn" or die "$fn: $!";
        
        # create cue file and write initial contents
        open CUE_OUT,'>',$cuefile or die "$cuefile: $!";
        print CUE_OUT "PERFORMER \"something\"\r\n";
        print CUE_OUT "TITLE \"something2\"\r\n";
        print CUE_OUT "FILE \"$fn\"\r\n";
        
        pipe(AUDIO_IN,AUDIO_OUT);
        AUDIO_OUT->autoflush(1);
        my $fd=fileno AUDIO_OUT;
        print STDERR "AUDIO_OUT fd is $fd\n";
        if ($recorder_pid = fork()) {
            # this is the parent process
            close AUDIO_OUT;
            do_recording(\*AUDIO_IN,\*MP3_OUT,\*CUE_OUT,$mp3_enc);
            close MP3_OUT;
            close CUE_OUT;
        } else {
            die "can not fork: $!" unless defined $recorder_pid;
            close AUDIO_IN;
            recorder_child();
        }
    };
    if ($@) {
        # handle error
        undef $mp3_enc;
        undef $recorder_pid;
        die $@;
    }
}

sub cue_entry {
    my ($fh,$mp3size,$tracknum,$title,$artist)=@_;
    # seconds = size*8/(kbps*1000)
    # szazadmasodperc = size*800/(kbps*1000) = size*8/(kbps*10)
    #   = size*4/kbps/5
    my $mp3time=int($mp3size*4/$record_config->{bit_rate}/5);
    my ($szazad,$sec,$min);
    {   use integer;
        $szazad=$mp3time % 100; $mp3time /= 100;
        $sec=$mp3time % 60;$mp3time /= 60;
        $min=$mp3time;
    }
    print "writing cuefile?\n";
    print Dumper($fh);
    print $fh "  TRACK $tracknum AUDIO\r\n";
    print $fh "    TITLE \"$title\"\r\n";
    print $fh "    PERFORMER \"$artist\"\r\n";
    print $fh "    INDEX $tracknum ${min}:${sec}:${szazad}\r\n";
}

# this code will receive pcm data from the recorder process
# encode to mp3 and write to file
sub do_recording {
    my ($audiofh,$mp3fh,$cuefh,$mp3enc)=@_;
    
    my $samplesize=$record_config->{num_channels}*2;    # we only support 16bit pcm samples
    
    # format of data blocks received from recording process:
    # - $samplesize samples 
    # - 5 bytes specifying time
    my $blocksize=$record_config->{detection_samples}*$samplesize + 5;
    print STDERR "blocksize: $blocksize\n";
    
    # variables for the big funky while loop
    my $data;
    my $retval;
    
    # state variables
    my $do_save=0;
    my $mp3size=0;      # position in mp3 output
    my @prerecord=();   # the infamous prerecord buffer
    my $silence=0;
    my $read=0;
    my $tracknum=1;
    TRY: while (1) {
        if ($do_exit==1) {
            stop_recording();
            $do_exit=2;
        }
        $retval=sysread($audiofh,$data,$blocksize-$read,$read);
        unless (defined $retval) {
            # error handling...
            next TRY if $!{EINTR};      # restart read() if interrupted by a signal
            next TRY if $!{EWOULDBLOCK};     # this is bullshit, we do not use nonblocking io
            die "reading from audio recorder process: $!";
        }
        last if $retval==0;         # stop recording, we've had enough
        
        $read+=$retval;
        if ($read<$blocksize) {next TRY;}
        $read=0;

        # no we can process the data
        my ($seconds,$szazad)=unpack 'LC',substr($data,-5,5);          # may use I instead of L if we check length of int for calculation of $blocksize 
        $data=substr($data,0,length($data)-5);

        #my $energy=sound_energy(\$data);
        my $energy=MP3Recorder::AudioUtils::sound_energy_S16_mono(\$data);
        
        # handle state transitions
        if ($energy>=$record_config->{threshold} && !$do_save) {
            # we start recording...
            print "START\n";
            $tracknum++;
            # TODO performer into cuefile
            {
                my ($sec,$min,$hour,$mday,$mon,$year,undef,undef,undef)=localtime $seconds;
                $year+=1900;$mon++;
                $szazad=sprintf('%02d',$szazad);
                cue_entry($cuefh,$mp3size,$tracknum,"#$tracknum $year-$mon-$mday $hour:$min:$sec.$szazad",'');
            }
            $do_save=1;
        }
        if ($energy>=$record_config->{threshold}) {$silence=0;}
        else {$silence++;}
        if ($do_save && ($silence*$record_config->{detection_period})>=$record_config->{silence_threshold}) {
            # silence for more than silence_threshold time detected
            # flush... afaik this appends some silence to the mp3 stream!!!
            # consider this when maintaining position in mp3 output file
            print "STOP\n";
            my $mp3=$mp3enc->encode_flush;
            if (length($mp3)) {
                print $mp3fh $mp3;
                $mp3size+=length($mp3);
            }
            $do_save=0;
        }
        
        {
            my $tmp=$data;
            push @prerecord,\$tmp;
        }
        while ((scalar(@prerecord)*$record_config->{detection_period})
            >= ($record_config->{prerecord}+$record_config->{detection_period})) {shift @prerecord;}
        #my $len=scalar(@prerecord);
        #print "prerecord length: $len\n";
            
        if ($do_save) {
            # write the whole @prerecord to mp3 file
            my $mp3;
            for my $block (@prerecord) {
                $mp3=$mp3enc->encode16($$block);
                if (length($mp3)) {
                    print $mp3fh $mp3;
                    $mp3size+=length($mp3);
                }
            }
            @prerecord=();
        }
    }
    print STDERR "received eof?\n";
    my $mp3=$mp3_enc->encode_flush;
    if (length($mp3)) {print $mp3fh $mp3;}
}

{
    # this block contains everything that runs in a separate process
    # grabs audio data from OSS and writes it to AUDIO_OUT with buffering
    # the buffer is implemented in Event::IOExtra
    my $self=+{};
    sub recorder_child {
        %$self=();
        $self->{buf}='';
        my $samplesize=$record_config->{num_channels}*2;    # we only support 16bit pcm samples
        $self->{blocksize}=$record_config->{detection_samples}*$samplesize;
        $self->{samplesize}=$samplesize;
        $self->{sr}=$record_config->{sample_rate};

        $self->{writer} = Event::IOExtra->new(
            'fd'=>\*AUDIO_OUT,
            'poll'=>'w'                # there is something wicked with this!!!
                                       # and it _did_ ruin everything, now!
                                       # TODO try to fix this in Event::IOExtra
        );
        
        $self->{input}=MP3Recorder::OSS->new(
            sample_rate=>$record_config->{sample_rate},
            num_channels=>$record_config->{num_channels},
            user_cb=>\&get_audio,
            user_data=>$self,
            device=>'/dev/dsp1'
        );
        'Event::signal'->new(
            signal=>'USR1',
            cb=>sub {
                my $e=shift;
                return if $self->{stopping};
                $self->{input}->stop_record;
                $self->{stopping}=1;
                $e->w->cancel;
            }
        );
        $self->{input}->start_record;
        Event::loop;                    # this terminates when both AUDIO_OUT's and the OSS's watcher cancels
        close AUDIO_OUT;
        print STDERR "recording process is exiting\n";
        exit 0;
    }

    # this is too simple now :)
    # we need a buffer to rearrange audio data into $blocksize blocks
    sub get_audio {
        my ($self,$dataref)=@_;
        return unless defined $dataref;
        $self->{buf}.=$$dataref;
        my $avail;
        while (length($self->{buf})>=$self->{blocksize}) {
            my ($most,$avail)=$self->{'input'}->get_bufinfo();
            # $avail specifies a time interval
            # subtract that time from $most
            $most -= $avail/$self->{samplesize}/$self->{sr};
            $most -= length($self->{buf})/$self->{samplesize}/$self->{sr};
            my $seconds=int($most);
            my $szazad=int(($most-$seconds)*100);
            my $block=substr($self->{buf},0,$self->{blocksize}).pack('LC',$seconds,$szazad);
            $self->{buf}=substr($self->{buf},$self->{blocksize});
            $self->{writer}->write(\$block);
        }
    }
}
