<?php
/**
 * Created by PhpStorm.
 * User: zein
 * Date: 7/4/14
 * Time: 2:31 PM
 */

namespace common\models\query;

use common\models\Article;
use common\models\ArticleCategory;
use yii\db\Expression;
use yii\db\ActiveQuery;
use Yii;

class ArticleQuery extends ActiveQuery
{
    /**
     * @return $this
     */
    public function published()
    {
        $this->andWhere(['{{%article}}.[[status]]' => Article::STATUS_PUBLISHED]);
        $this->andWhere(['<', '{{%article}}.[[published_at]]', time()]);
        return $this;
    }

    public function getFullArchive()
    {
        $this->innerJoin('{{%article_category}}', '{{%article_category}}.[[id]] = {{%article}}.[[category_id]]');
        $this->select([
            'year' => new Expression($this->dateExpression('year')),
            'month' => new Expression($this->dateExpression('month')),
            'count' => new Expression('COUNT(*)'),
        ]);
        $this->published();
        $this->andWhere(['{{%article_category}}.[[status]]' => ArticleCategory::STATUS_ACTIVE]);
        $this->groupBy(['year', 'month']);
        $this->orderBy(['year' => SORT_DESC, 'month' => SORT_DESC]);
        return $this;
    }

    private function dateExpression($part)
    {
        $part = strtoupper($part);

        if (Yii::$app->db->driverName === 'pgsql') {
            return 'EXTRACT(' . $part . ' FROM TO_TIMESTAMP({{%article}}.[[published_at]]))::int';
        }

        return $part . '(FROM_UNIXTIME({{%article}}.[[published_at]]))';
    }
}
