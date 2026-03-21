<?php

namespace frontend\models\search;

use yii\base\Model;
use yii\data\ActiveDataProvider;
use common\models\Article;
use common\models\ArticleCategory;
use yii\db\Expression;
use Yii;

/**
 * ArticleSearch represents the model behind the search form about `common\models\Article`.
 */
class ArticleSearch extends Article
{
    public $year;
    public $month;

    /**
     * @inheritdoc
     */
    public function rules()
    {
        return [
            [['id', 'category_id', 'year', 'month'], 'integer'],
            [['slug', 'title'], 'safe'],
        ];
    }

    /**
     * @inheritdoc
     */
    public function scenarios()
    {
        // bypass scenarios() implementation in the parent class
        return Model::scenarios();
    }

    /**
     * Creates data provider instance with search query applied
     * @return ActiveDataProvider
     */
    public function search($params)
    {
        $query = Article::find()
            ->joinWith('category')
            ->andWhere(['{{%article_category}}.[[status]]' => ArticleCategory::STATUS_ACTIVE])
            ->published();

        $dataProvider = new ActiveDataProvider([
            'query' => $query,
        ]);

        if (!($this->load($params) && $this->validate())) {
            return $dataProvider;
        }

        $query->andFilterWhere([
            'id' => $this->id,
            'slug' => $this->slug,
            'category_id' => $this->category_id,
        ]);
        $query->andFilterWhere(['=', new Expression($this->dateExpression('year')), $this->year]);
        $query->andFilterWhere(['=', new Expression($this->dateExpression('month')), $this->month]);

        $query->andFilterWhere(['like', 'title', $this->title]);

        return $dataProvider;
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
