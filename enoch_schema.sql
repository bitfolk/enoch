DROP TABLE IF EXISTS `nick`;
CREATE TABLE `nick` (
  `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `nick` varchar(32) NOT NULL DEFAULT '',
  PRIMARY KEY (`id`),
  UNIQUE KEY `nick` (`nick`)
) ENGINE=InnoDB  DEFAULT CHARSET=utf8;

DROP TABLE IF EXISTS `quote`;
CREATE TABLE `quote` (
  `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `channel` varchar(64) NOT NULL DEFAULT '',
  `quote` text NOT NULL,
  `nick` varchar(32) NOT NULL DEFAULT '',
  `nick_id` int(10) unsigned NOT NULL DEFAULT '0',
  `added` datetime DEFAULT NULL,
  `rating` float unsigned NOT NULL DEFAULT '0',
  PRIMARY KEY (`id`),
  KEY `nick` (`nick`),
  KEY `channel` (`channel`),
  KEY `nick_id` (`nick_id`)
) ENGINE=InnoDB  DEFAULT CHARSET=utf8;

DROP TABLE IF EXISTS `rating`;
CREATE TABLE `rating` (
  `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `nick_id` int(10) unsigned NOT NULL DEFAULT '0',
  `quote_id` int(10) unsigned NOT NULL DEFAULT '0',
  `rating` smallint(2) unsigned NOT NULL DEFAULT '0',
  PRIMARY KEY (`id`),
  UNIQUE KEY `nick_quote_id` (`nick_id`,`quote_id`),
  KEY `quote_id` (`quote_id`)
) ENGINE=InnoDB  DEFAULT CHARSET=utf8;

