<?php
/*
 * BandwidthLib
 *
 * This file was automatically generated by APIMATIC v2.0 ( https://apimatic.io ).
 */

namespace BandwidthLib\Messaging\Models;

/**
 * @todo Write general description for this model
 */
class BandwidthMessage implements \JsonSerializable
{
    /**
     * The id of the message
     * @var string|null $id public property
     */
    public $id;

    /**
     * The Bandwidth phone number associated with the message
     * @var string|null $owner public property
     */
    public $owner;

    /**
     * The application ID associated with the message
     * @var string|null $applicationId public property
     */
    public $applicationId;

    /**
     * The datetime stamp of the message in ISO 8601
     * @var string|null $time public property
     */
    public $time;

    /**
     * The number of segments the original message from the user is broken into before sending over to
     * carrier networks
     * @var integer|null $segmentCount public property
     */
    public $segmentCount;

    /**
     * The direction of the message relative to Bandwidth. Can be in or out
     * @var string|null $direction public property
     */
    public $direction;

    /**
     * The phone number recipients of the message
     * @var array|null $to public property
     */
    public $to;

    /**
     * The phone number the message was sent from
     * @var string|null $from public property
     */
    public $from;

    /**
     * The list of media URLs sent in the message
     * @var array|null $media public property
     */
    public $media;

    /**
     * The contents of the message
     * @var string|null $text public property
     */
    public $text;

    /**
     * The custom string set by the user
     * @var string|null $tag public property
     */
    public $tag;

    /**
     * The priority specified by the user
     * @var string|null $priority public property
     */
    public $priority;

    /**
     * Constructor to set initial or default values of member properties
     */
    public function __construct()
    {
        if (12 == func_num_args()) {
            $this->id            = func_get_arg(0);
            $this->owner         = func_get_arg(1);
            $this->applicationId = func_get_arg(2);
            $this->time          = func_get_arg(3);
            $this->segmentCount  = func_get_arg(4);
            $this->direction     = func_get_arg(5);
            $this->to            = func_get_arg(6);
            $this->from          = func_get_arg(7);
            $this->media         = func_get_arg(8);
            $this->text          = func_get_arg(9);
            $this->tag           = func_get_arg(10);
            $this->priority      = func_get_arg(11);
        }
    }

    /**
     * Encode this object to JSON
     */
    public function jsonSerialize()
    {
        $json = array();
        $json['id']            = $this->id;
        $json['owner']         = $this->owner;
        $json['applicationId'] = $this->applicationId;
        $json['time']          = $this->time;
        $json['segmentCount']  = $this->segmentCount;
        $json['direction']     = $this->direction;
        $json['to']            = isset($this->to) ?
            array_values($this->to) : null;
        $json['from']          = $this->from;
        $json['media']         = isset($this->media) ?
            array_values($this->media) : null;
        $json['text']          = $this->text;
        $json['tag']           = $this->tag;
        $json['priority']      = $this->priority;

        return array_filter($json);
    }
}
