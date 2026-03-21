<?php

namespace tests\common\fixtures;

use common\models\User;
use Yii;
use yii\test\ActiveFixture;

/**
 * User fixture
 */
class UserFixture extends ActiveFixture
{
    public $modelClass = User::class;

    public function afterLoad()
    {
        parent::afterLoad();

        if (Yii::$app->db->driverName !== 'pgsql') {
            return;
        }

        Yii::$app->db->createCommand(
            "SELECT setval(pg_get_serial_sequence('{{%user}}', 'id'), COALESCE(MAX([[id]]), 0) + 1, false) FROM {{%user}}"
        )->execute();
    }
}
