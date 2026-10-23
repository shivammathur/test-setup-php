<?php
$command=json_decode(COMMAND_JSON,true);
$active=[];$done=[];$next=0;$total=900;
while ($next<$total || $active) {
    while($next<$total && count($active)<6) {
        $pipes=[];$p=proc_open($command,[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);
        if(!is_resource($p))throw new Exception('proc_open failed');
        fclose($pipes[0]);stream_set_blocking($pipes[1],false);stream_set_blocking($pipes[2],false);
        $active[$next++]=['proc'=>$p,'pipes'=>$pipes,'out'=>'','err'=>''];
    }
    foreach($active as $id=>&$a) {
        $a['out'].=stream_get_contents($a['pipes'][1]);$a['err'].=stream_get_contents($a['pipes'][2]);
        $s=proc_get_status($a['proc']);
        if (!$s['running']) {
            $a['out'].=stream_get_contents($a['pipes'][1]);$a['err'].=stream_get_contents($a['pipes'][2]);
            fclose($a['pipes'][1]);fclose($a['pipes'][2]);proc_close($a['proc']);
            $done[]=['id'=>$id,'status'=>$s,'stdout'=>$a['out'],'stderr'=>$a['err']];unset($active[$id]);
            file_put_contents(RESULT_JSON,json_encode($done));
        }
    }
    unset($a);usleep(1000);
}
echo json_encode(['completed'=>count($done),'bad'=>count(array_filter($done,fn($x)=>$x['status']['exitcode']!==0))]),"\n";
