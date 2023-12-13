<?php

namespace Cesurapp\SwooleBundle\Tests\_App\Controller;

use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

class AcmeHome
{
    #[Route(path: '/')]
    public function home(): Response
    {
        return new Response('ok');
    }
}
