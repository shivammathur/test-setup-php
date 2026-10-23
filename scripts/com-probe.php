<?php
$results=[];
for ($i=0;$i<100;$i++) {
    foreach (['skipif','test'] as $stage) {
        try {
            $ie=new COM('InternetExplorer.Application');
            $x=0;$y=0;
            if ($stage==='test') { try { $ie->clientToWindow($x,$y); } catch (com_exception $e) {} }
            $ie->quit();unset($ie);
            $results[]=['iteration'=>$i,'stage'=>$stage,'ok'=>true,'x'=>$x,'y'=>$y];
        } catch (com_exception $e) {
            $results[]=['iteration'=>$i,'stage'=>$stage,'ok'=>false,'hresult'=>sprintf('0x%08X',$e->getCode() & 0xffffffff),'message'=>$e->getMessage()];
        }
    }
}
echo json_encode($results),"\n";
