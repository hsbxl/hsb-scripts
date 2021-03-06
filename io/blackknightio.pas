program blackknightio;
{
 Make I/O on a shift register (74LS673) coupled to an input multiplexer (74150)
 using a raspberry pi and only 4 GPIO lines

 (c) 2013 Frederic Pasteleurs <frederic@askarel.be>

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program or from the site that you downloaded it
 from; if not, see <http://www.gnu.org/licenses/>.

 The PiGPIO library included in this repository is (c) 2013 Gábor Szöllösi
}

// This is a quick hack to check if everything works
{
 TODO:
 - Daemon mode
   * start/stop
   * Program name: /proc/<pid>/comm = basename (paramstr (0))

}

uses PiGpio, sysutils, crt, keyboard, strutils;

TYPE    TDbgArray= ARRAY [0..15] OF string[15];
        TRegisterbits=bitpacked array [0..15] of boolean; // Like a word: a 16 bits bitfield
        TSHMVariables=RECORD // What items should be exposed for IPC.
                Input, output: TRegisterbits;
                QUIT: boolean;
                end;

CONST   CLOCKPIN=7;  // 74LS673 pins
        STROBEPIN=8;
        DATAPIN=25;
        READOUTPIN=4; // Output of 74150
        bits:array [false..true] of char=('0', '1');

        // Available outputs on 74LS673. Outputs Q0 to Q3 are connected to the address inputs of the 74150
        Q15=1; Q14=2; Q13=4; Q12=8; Q11=16; Q10=32; Q9=64; Q8=128; Q7=256; Q6=512; Q5=1024; Q4=2048;
        // Use more meaningful descriptions of the outputs in the code
        // Outputs Q4, Q12, Q13, Q14 and Q15 are not used for the moment. Status LED maybe ?
        BUZZER_OUPUT_TRANSISTOR=Q11;
        BATTERY_RELAY=Q10;
        MAGLOCK1_RELAY=Q9;
        MAGLOCK2_RELAY=Q8;
        DOOR_STRIKE_RELAY=Q7;
        LIGHT_CONTROL_RELAY=Q6;
        DOORBELL_INHIBIT_RELAY=Q5;
        // Available inputs from the 74150
        I15=32768; I14=16384; I13=8192; I12=4096; I11=2048; I10=1024; I9=512; I8=256; I7=128; I6=64; I5=32; I4=16; I3=8; I2=4; I1=2; I0=1;
        // Use more meaningful descriptions of the inputs in the code
        // Inputs OPTO4, IN3, IN2 and IN1 are not used for the moment.
        IN11=I0; IN10=I1; IN9=I2; IN8=I3; IN7=I4; IN6=I5; IN5=I6; IN4=I7; IN3=I8; IN2=I9; IN1=I10; OPTO1=I12; OPTO2=I13; OPTO3=I14; OPTO4=I15;
        PANIC_SENSE=I11;
        DOORBELL1=OPTO1;
        DOORBELL2=OPTO2;
        DOORBELL3=OPTO3;
        BOX_TAMPER_SWITCH=IN11;
        TRIPWIRE_LOOP=IN10;
        MAGLOCK1_RETURN=IN9;
        MAGLOCK2_RETURN=IN8;
        DOORHANDLE=IN7;
        LIGHTS_ON_SENSE=IN6;
        DOOR_CLOSED_SWITCH=IN5;
        MAIL_DETECTION=IN4;     // Of course we'll have physical mail notification. :-)
        IS_CLOSED=false;
        IS_OPEN=true;
        DBGINSTATESTR: Array [IS_CLOSED..IS_OPEN] of string[5]=('closed', 'open');
        DBGOUTSTATESTR: Array [false..true] of string[5]=('On', 'Off');
        DBGOUT: TDbgArray=('Q15 not used', 'Q14 not used', 'Q13 not used', 'Q12 not used', 'buzzer', 'battery', 'mag1 power', 'mag2 power', 'strike',
                                'light', 'bell inhib.', 'Q4 not used', '74150 A3', '74150 A2', '74150 A1', '74150 A0');
        DBGIN: TDbgArray=('TAMPER BOX','TRIPWIRE','MAG1 CLOSED','MAG2 CLOSED','HANDLE','LIGHT ON','DOOR SWITCH','MAILBOX','IN 3',
                                'IN 2','IN 1','PANIC SWITCH','DOORBELL 1','DOORBELL 2','DOORBELL 3','OPTO 4');


VAR     GPIO_Driver: TIODriver;
        GpF: TIOPort;
        QUIT: boolean;

///////////// COMMON LIBRARY FUNCTIONS /////////////

// Return gray-encoded input
function graycode (inp: longint): longint;
begin
 graycode:=(inp shr 1) xor inp;
end;

function word2bits (inputword: word): TRegisterbits;
begin
 word2bits:=TRegisterbits (inputword); // TRegisterbits is a word-sized array of bits
end;

function bits2word (inputbits: TRegisterbits): word;
begin
 bits2word:=word (inputbits);
end;

function bits2str (inputbits: TRegisterbits): string;
var i: byte;
    s: string;
begin
 s:='';
 for i:=(bitsizeof (TRegisterbits)-1) downto 0 do s:=s+bits[inputbits[i]];
 bits2str:=s;
end;


///////////// DEBUG FUNCTIONS /////////////
{
// Transform the input number into a bitfield string
function bitify (inword: longint; size: byte): string;
const bits:array[0..1] of char=('0','1');
var i: byte;
    s: string;
begin
 s:='';
 for i:=(size - 1) downto 0 do s:=s+bits[(inword shr i) and 1];
 bitify:=s;
end;
 }

// This is an ugly mess that should be removed.
function debug_alterinput(inbits: TRegisterbits): TRegisterbits;
var cmdstr, cmd, bit, key: string;
    bitnumber, errcode: byte;
    K: TKeyEvent;
begin
 K:=PollKeyEvent; // Check for keyboard input
 cmdstr:='';
 if k<>0 then // Key pressed ?
  begin
   write ('Alter input >>> ');
   repeat
    k:=TranslateKeyEvent (GetKeyEvent);
    key:= KeyEventToString (k);
    write (key);
    if key <> #13 then cmdstr:=cmdstr + Key;
   until key = #13; // ENTER pressed
   cmdstr:=trim (delspace1 (cmdstr));
//   case extractword (1, cmdstr, [' ']) of // Internal error 200211262
   cmd:=extractword (1, cmdstr, [' ']); // Working around compiler bug
   case cmd of
    'quit': QUIT:=true;
    'setbit':
      begin
       val (extractword (2, cmdstr, [' ']), bitnumber, errcode);
       bit:=extractword (3, cmdstr, [' ']);
       if (errcode = 0) and (bitnumber >= 0) and (bitnumber <= 15) then
        case bit of // We have good data !
         '1':inbits[bitnumber]:=true;
         '0':inbits[bitnumber]:=false;
        else writeln ('Value for bit ', bitnumber, ' should be 0 or 1, not ', bit, '.       ');
        end
       else writeln ('''', extractword (2, cmdstr, [' ']), ''' is not a valid bit.          ');
      end;
   else writeln (cmdstr, ': invalid command.');
   end;
  end;
  debug_alterinput:=inbits;
end;

// Decompose a word into bitfields with description
procedure debug_showword (inputbits: TRegisterbits; screenshift: byte; description: TDbgArray );
var i: byte;
begin
 for i:=0 to 15 do
  begin
   description[i][0]:=char (15);// Trim length
   gotoxy (1 + screenshift, i + 1); write ( bits[inputbits[i]], ' ', description[i]);
//   sleep (20);
  end;
  writeln;
end;

///////////// CHIP HANDLING FUNCTIONS /////////////

// Send out a word to the 74LS673
procedure write74673 (clockpin, datapin, strobepin: byte; data: TRegisterbits);
var i: byte;
begin
 for i:=0 to 15 do
 begin
  GpF.SetBit (clockpin);
  if data[i] then GpF.SetBit (datapin) else GpF.Clearbit (datapin);
  GpF.ClearBit (clockpin);
 end;
// GpF.SetBit (datapin); // Is that line needed ?
 GpF.SetBit (strobepin);
 GpF.Clearbit (strobepin);
end;

// Do an I/O cycle on the board
function io_673_150 (clockpin, datapin, strobepin, readout: byte; data:word): TRegisterbits;
var i: byte;
    gpioword: word;
begin
 gpioword:=0;
 for i:=0 to 15 do
  begin
   write74673 (clockpin, datapin, strobepin, word2bits ((data and $0fff) or (graycode (i) shl $0c)) );
   sleep (1);
   gpioword:=(gpioword or (ord (GpF.GetBit (readout)) shl graycode(i) ) );
  end;
 io_673_150:=word2bits (gpioword);
end;

procedure lock_brain (var inputs, outputs: word);
begin

end;

///////////// MAIN BLOCK /////////////
var  ii: byte;
     inputs, outputs: TRegisterbits;
begin
 initkeyboard;
 outputs:=word2bits (0);
 QUIT:=false;
 case paramstr (1) of
  'start':
   begin
   if not GPIO_Driver.MapIo then { No GPIO ? }
    begin
     writeln('Error mapping gpio registry');
     halt (1);
    end;
   GpF := GpIo_Driver.CreatePort(GPIO_BASE, CLOCK_BASE, GPIO_PWM);
   GpF.SetPinMode (CLOCKPIN, OUTPUT);
   GpF.setpinmode (STROBEPIN, OUTPUT);
   GpF.setpinmode (DATAPIN, OUTPUT);
   GpF.setpinmode (READOUTPIN, INPUT);

   repeat
   inputs:=io_673_150 (CLOCKPIN, DATAPIN, STROBEPIN, READOUTPIN, bits2word (outputs));

   until false;
   end;

   'test':
   begin
//    for ii:=0 to 63 do writeln (bitify (ii, 16), ' -> ', bitify (graycode (ii), 16));
   clrscr;
   repeat
//   inputs:=io_673_150 (CLOCKPIN, DATAPIN, STROBEPIN, READOUTPIN, outputs);
    for ii:=0 to 11 do
     begin
      inputs:=debug_alterinput (inputs);
      debug_showword (word2bits (1 shl ii), 0, DBGOUT);
      debug_showword (inputs, 25, DBGIN);
      writeln ('cycle up  : ', hexstr (ii, 2), ', Write: ', bits2str ( word2bits (1 shl ii)), '.');
     end;
    for ii:=11 downto 0 do
     begin
      debug_showword (word2bits (1 shl ii), 0, DBGOUT);
      debug_showword (inputs, 25, DBGIN);
      writeln ('cycle down: ', hexstr(ii, 2), ', Write: ', bits2str ( word2bits (1 shl ii)), '.');
     end;
    until QUIT;
   end;

   'testpattern':
   begin
   if not GPIO_Driver.MapIo then
    begin
     writeln('Error mapping gpio registry');
     halt (1);
    end;
   GpF := GpIo_Driver.CreatePort(GPIO_BASE, CLOCK_BASE, GPIO_PWM);
   GpF.SetPinMode (CLOCKPIN, OUTPUT);
   GpF.setpinmode (STROBEPIN, OUTPUT);
   GpF.setpinmode (DATAPIN, OUTPUT);
   GpF.setpinmode (READOUTPIN, INPUT);
   repeat
   inputs:=io_673_150 (CLOCKPIN, DATAPIN, STROBEPIN, READOUTPIN, bits2word (outputs));
    for ii:=0 to 11 do
     begin
      writeln ('cycle up  : ', hexstr (ii, 2), ', Write: ', bits2str ( word2bits (1 shl ii)), ', read: ', bits2str (io_673_150 (CLOCKPIN, DATAPIN, STROBEPIN, READOUTPIN, (1 shl ii))), '.');
     end;
    for ii:=11 downto 0 do
     begin
      writeln ('cycle down: ', hexstr (ii, 2), ', Write: ', bits2str ( word2bits (1 shl ii)), ', read: ', bits2str (io_673_150 (CLOCKPIN, DATAPIN, STROBEPIN, READOUTPIN, (1 shl ii))), '.');
     end;
    until false;
   end;

   '':
   begin
    writeln ('Usage: ', paramstr (0), ' [start|stop|test|open|diag]');
    halt (1);
   end;
 end;
// writeln;writeln;
// writeln (bitsizeof (TRegisterbits), '    ', bits2str (word2bits ( I4)), '    ', boolean (0));

 donekeyboard;
end.
