<?php
namespace Craft;

/**
 *
 */
class SectionsService extends BaseApplicationComponent
{
	public $typeLimits;

	private $_allSectionIds;
	private $_editableSectionIds;

	private $_sectionsById;
	private $_fetchedAllSections = false;

	private $_entryTypesById;

	/**
	 * Returns all of the section IDs.
	 *
	 * @return array
	 */
	public function getAllSectionIds()
	{
		if (!isset($this->_allSectionIds))
		{
			$query = craft()->db->createCommand()
				->select('id')
				->from('sections');

			$this->_allSectionIds = $query->queryColumn();
		}

		return $this->_allSectionIds;
	}

	/**
	 * Returns all of the section IDs that are editable by the current user.
	 *
	 * @return array
	 */
	public function getEditableSectionIds()
	{
		if (!isset($this->_editableSectionIds))
		{
			$this->_editableSectionIds = array();
			$allSectionIds = $this->getAllSectionIds();

			foreach ($allSectionIds as $sectionId)
			{
				if (craft()->userSession->checkPermission('editEntries:'.$sectionId))
				{
					$this->_editableSectionIds[] = $sectionId;
				}
			}
		}

		return $this->_editableSectionIds;
	}

	/**
	 * Returns all sections.
	 *
	 * @param string|null $indexBy
	 * @return array
	 */
	public function getAllSections($indexBy = null)
	{
		if (!$this->_fetchedAllSections)
		{
			$criteria = new \CDbCriteria();

			$sectionRecords = SectionRecord::model()->ordered()->findAll($criteria);
			$this->_sectionsById = SectionModel::populateModels($sectionRecords, 'id');
			$this->_fetchedAllSections = true;
		}

		if ($indexBy == 'id')
		{
			$sections = $this->_sectionsById;
		}
		else if (!$indexBy)
		{
			$sections = array_values($this->_sectionsById);
		}
		else
		{
			$sections = array();
			foreach ($this->_sectionsById as $section)
			{
				$sections[$section->$indexBy] = $section;
			}
		}

		return $sections;
	}

	/**
	 * Returns all editable sections.
	 *
	 * @param string|null $indexBy
	 * @return array
	 */
	public function getEditableSections($indexBy = null)
	{
		$sections = $this->getAllSections();
		$editableSectionIds = $this->getEditableSectionIds();
		$editableSections = array();

		foreach ($sections as $section)
		{
			if (in_array($section->id, $editableSectionIds))
			{
				if ($indexBy)
				{
					$editableSections[$section->$indexBy] = $section;
				}
				else
				{
					$editableSections[] = $section;
				}
			}
		}

		return $editableSections;
	}

	/**
	 * Gets the total number of sections.
	 *
	 * @return int
	 */
	public function getTotalSections()
	{
		return count($this->getAllSectionIds());
	}

	/**
	 * Gets the total number of sections that are editable by the current user.
	 *
	 * @return int
	 */
	public function getTotalEditableSections()
	{
		return count($this->getEditableSectionIds());
	}

	/**
	 * Returns a section by its ID.
	 *
	 * @param $sectionId
	 * @return SectionModel|null
	 */
	public function getSectionById($sectionId)
	{
		// If we've already fetched all sections we can save ourselves a trip to the DB
		// for section IDs that don't exist
		if (!$this->_fetchedAllSections &&
			(!isset($this->_sectionsById) || !array_key_exists($sectionId, $this->_sectionsById))
		)
		{
			$sectionRecord = SectionRecord::model()->findById($sectionId);

			if ($sectionRecord)
			{
				$this->_sectionsById[$sectionId] = SectionModel::populateModel($sectionRecord);
			}
			else
			{
				$this->_sectionsById[$sectionId] = null;
			}
		}

		if (isset($this->_sectionsById[$sectionId]))
		{
			return $this->_sectionsById[$sectionId];
		}
	}

	/**
	 * Gets a section by its handle.
	 *
	 * @param string $sectionHandle
	 * @return SectionModel|null
	 */
	public function getSectionByHandle($sectionHandle)
	{
		$sectionRecord = SectionRecord::model()->findByAttributes(array(
			'handle' => $sectionHandle
		));

		if ($sectionRecord)
		{
			return SectionModel::populateModel($sectionRecord);
		}
	}

	/**
	 * Returns a section's locales.
	 *
	 * @param int $sectionId
	 * @param string|null $indexBy
	 * @return array
	 */
	public function getSectionLocales($sectionId, $indexBy = null)
	{
		$records = SectionLocaleRecord::model()->findAllByAttributes(array(
			'sectionId' => $sectionId
		));

		return SectionLocaleModel::populateModels($records, $indexBy);
	}

	/**
	 * Saves a section.
	 *
	 * @param SectionModel $section
	 * @throws \Exception
	 * @return bool
	 */
	public function saveSection(SectionModel $section)
	{
		if ($section->id)
		{
			$sectionRecord = SectionRecord::model()->findById($section->id);

			if (!$sectionRecord)
			{
				throw new Exception(Craft::t('No section exists with the ID “{id}”', array('id' => $sectionId)));
			}

			$isNewSection = false;
			$oldSection = SectionModel::populateModel($sectionRecord);
		}
		else
		{
			$sectionRecord = new SectionRecord();
			$isNewSection = true;
		}

		// Shared attributes
		$sectionRecord->name    = $section->name;
		$sectionRecord->handle  = $section->handle;
		$sectionRecord->type    = $section->type;

		if (($isNewSection || $section->type != $oldSection->type) && !$this->canHaveMore($section->type))
		{
			$section->addError('type', Craft::t('You can’t add any more {type} sections.', array('type' => Craft::t(ucfirst($section->type)))));
		}

		// Type-specific attributes
		if ($section->type == SectionType::Single)
		{
			$sectionRecord->hasUrls = $section->hasUrls = true;
		}
		else
		{
			$sectionRecord->hasUrls = $section->hasUrls;
		}

		if ($section->hasUrls)
		{
			$sectionRecord->template = $section->template;
		}
		else
		{
			$sectionRecord->template = $section->template = null;
		}

		if ($section->type == SectionType::Structure)
		{
			$sectionRecord->maxDepth = $section->maxDepth;
		}
		else
		{
			$sectionRecord->maxDepth = $section->maxDepth = null;
		}

		$sectionRecord->validate();
		$section->addErrors($sectionRecord->getErrors());

		// Make sure that all of the URL formats are set properly
		foreach ($section->getLocales() as $localeId => $sectionLocale)
		{
			if ($section->type == SectionType::Single)
			{
				$errorKey = 'urlFormat-'.$localeId;

				if (empty($sectionLocale->urlFormat))
				{
					$section->addError($errorKey, Craft::t('URI cannot be blank.'));
				}
				else if ($section)
				{
					// Make sure no other elements are using this URI already
					$query = craft()->db->createCommand()
						->from('elements_i18n elements_i18n')
						->where(
							array('and', 'elements_i18n.locale = :locale', 'elements_i18n.uri = :uri'),
							array(':locale' => $localeId, ':uri' => $sectionLocale->urlFormat)
						);

					if ($section->id)
					{
						$query->join('entries entries', 'entries.id = elements_i18n.elementId')
							->andWhere('entries.sectionId != :sectionId', array(':sectionId' => $section->id));
					}

					$count = $query->count('elements_i18n.id');

					if ($count)
					{
						$section->addError($errorKey, Craft::t('This URI is already in use.'));
					}
				}

				$sectionLocale->nestedUrlFormat = null;
			}
			else if ($section->hasUrls)
			{
				$urlFormatAttributes = array('urlFormat');

				if ($section->type == SectionType::Structure)
				{
					$urlFormatAttributes[] = 'nestedUrlFormat';
				}
				else
				{
					$sectionLocale->nestedUrlFormat = null;
				}

				foreach ($urlFormatAttributes as $urlFormatAttribute)
				{
					$errorKey = $urlFormatAttribute.'-'.$localeId;

					if (empty($sectionLocale->$urlFormatAttribute))
					{
						$section->addError($errorKey, Craft::t('URL formats cannot be blank.'));
					}
					else if (mb_strpos($sectionLocale->$urlFormatAttribute, '{slug}') === false)
					{
						$section->addError($errorKey, Craft::t('URL formats must contain “{slug}”'));
					}
				}
			}
			else
			{
				$sectionLocale->urlFormat = null;
				$sectionLocale->nestedUrlFormat = null;
			}
		}

		if (!$section->hasErrors())
		{
			$transaction = craft()->db->getCurrentTransaction() === null ? craft()->db->beginTransaction() : null;
			try
			{
				$sectionRecord->save(false);

				// Now that we have a section ID, save it on the model
				if (!$section->id)
				{
					$section->id = $sectionRecord->id;
				}

				// Might as well update our cache of the section while we have it.
				// (It's possilbe that the URL format includes {section.handle} or something...)
				$this->_sectionsById[$section->id] = $section;

				// Update the sections_i18n table
				$newLocaleData = array();

				if (!$isNewSection)
				{
					// Get the old section locales
					$oldSectionLocaleRecords = SectionLocaleRecord::model()->findAllByAttributes(array(
						'sectionId' => $section->id
					));
					$oldSectionLocales = SectionLocaleModel::populateModels($oldSectionLocaleRecords, 'locale');
				}

				foreach ($section->getLocales() as $localeId => $locale)
				{
					$updateEntries = false;

					// Was this already selected?
					if (!$isNewSection && isset($oldSectionLocales[$localeId]))
					{
						$oldLocale = $oldSectionLocales[$localeId];

						// Has the URL format changed?
						if ($locale->urlFormat != $oldLocale->urlFormat || $locale->nestedUrlFormat != $oldLocale->nestedUrlFormat)
						{
							craft()->db->createCommand()->update('sections_i18n', array(
								'urlFormat'       => $locale->urlFormat,
								'nestedUrlFormat' => $locale->nestedUrlFormat
							), array(
								'id' => $oldLocale->id
							));

							$updateEntries = true;
						}
					}
					else
					{
						$newLocaleData[] = array($section->id, $localeId, $locale->urlFormat, $locale->nestedUrlFormat);

						if (!$isNewSection)
						{
							$updateEntries = true;
						}
					}

					if ($updateEntries && $section->type != SectionType::Single && $section->hasUrls)
					{
						// This may take a while...
						set_time_limit(120);

						// Fetch all the enabled entries in this section
						$entries = craft()->elements->getCriteria(ElementType::Entry, array(
							'sectionId' => $section->id,
							'locale'    => $localeId,
							'limit'     => null,
						))->find();

						foreach ($entries as $entry)
						{
							if ($section->type == SectionType::Structure && $entry->depth > 1)
							{
								$urlFormatAttribute = 'nestedUrlFormat';
							}
							else
							{
								$urlFormatAttribute = 'urlFormat';
							}

							$uri = craft()->templates->renderObjectTemplate($locale->$urlFormatAttribute, $entry);

							if ($uri != $entry->uri)
							{
								craft()->db->createCommand()->update('elements_i18n',
									array('uri' => $uri),
									array('elementId' => $entry->id, 'locale' => $localeId)
								);
							}
						}
					}
				}

				// Insert the new locales
				craft()->db->createCommand()->insertAll('sections_i18n',
					array('sectionId', 'locale', 'urlFormat', 'nestedUrlFormat'),
					$newLocaleData
				);

				if (!$isNewSection)
				{
					// Drop the old ones
					$disabledLocaleIds = array_diff(array_keys($oldSectionLocales), array_keys($section->getLocales()));
					foreach ($disabledLocaleIds as $localeId)
					{
						craft()->db->createCommand()->delete('sections_i18n', array('id' => $oldSectionLocales[$localeId]->id));
					}

					// Get all of the entry IDs in this section
					$sectionEntryIds = craft()->db->createCommand()
						->select('id')
						->from('entries')
						->where(array('sectionId' => $section->id))
						->queryColumn();

					// Drop the old entry URIs if the section no longer has URLs
					if (!$section->hasUrls && $oldSection->hasUrls)
					{
						craft()->db->createCommand()->update('elements_i18n',
							array('uri' => null),
							array('in', 'elementId', $sectionEntryIds)
						);
					}

					// Drop any rows in the i18n tables that are no longer needed
					$conditions = array('and', array('in', 'elementId', $sectionEntryIds));

					if ($section->getLocales())
					{
						$conditions[] = array('not in', 'locale', array_keys($section->getLocales()));
					}

					craft()->db->createCommand()->delete('elements_i18n', $conditions);
					craft()->db->createCommand()->delete('content', $conditions);

					$conditions[1][1] = 'entryId';
					craft()->db->createCommand()->delete('entries_i18n', $conditions);
				}

				// Make sure there's at least one entry type for this section
				$entryTypeId = null;

				if (!$isNewSection)
				{
					// Let's grab all of the entry type IDs to save ourselves a query down the road if this is a Single
					$entryTypeIds = craft()->db->createCommand()
						->select('id')
						->from('entrytypes')
						->where('sectionId = :sectionId', array(':sectionId' => $section->id))
						->queryColumn();

					if ($entryTypeIds)
					{
						$entryTypeId = array_shift($entryTypeIds);
					}
				}

				if (!$entryTypeId)
				{
					$entryType = new EntryTypeModel();
					$entryType->sectionId  = $section->id;
					$entryType->name       = $section->name;
					$entryType->handle     = $section->handle;
					$entryType->titleLabel = Craft::t('Title');
					$this->saveEntryType($entryType);

					$entryTypeId = $entryType->id;
				}

				// Did the section type just change?
				if (!$isNewSection && $oldSection->type != $section->type)
				{
					// Give the old section type a chance to do a little cleanup
					switch ($oldSection->type)
					{
						case SectionType::Structure:
						{
							// Get the root node
							$rootNodeRecord = StructuredEntryRecord::model()->roots()->findByAttributes(array(
								'sectionId' => $section->id
							));

							// Remove all of the hierarchical data
							craft()->db->createCommand()->update('entries', array(
								'root'  => false,
								'lft'   => null,
								'rgt'   => null,
								'depth' => null,
							), array(
								'sectionId' => $section->id
							));

							if ($rootNodeRecord)
							{
								craft()->elements->deleteElementById($rootNodeRecord->id);
							}

							break;
						}
					}
				}

				// Now, regardless of whether the section type changed or not,
				// let the section type make sure everything's cool

				switch ($section->type)
				{
					case SectionType::Single:
					{
						// In a nut, we want to make sure that there is one and only one Entry Type and Entry for this section.
						// We also want to make sure the entry has rows in the i18n tables for each of the sections' locales.

						$singleEntryId = null;

						if (!$isNewSection)
						{
							// Make sure there's only one entry in this section
							$entryIds = craft()->db->createCommand()
								->select('id')
								->from('entries')
								->where('sectionId = :sectionId', array(':sectionId' => $section->id))
								->queryColumn();

							if ($entryIds)
							{
								$singleEntryId = array_shift($entryIds);

								// If there are any more, get rid of them
								if ($entryIds)
								{
									craft()->elements->deleteElementById($entryIds);
								}

								// Make sure it's enabled and all that.

								craft()->db->createCommand()->update('elements', array(
									'enabled'    => 1,
									'archived'   => 0,
								), array(
									'id' => $singleEntryId
								));

								craft()->db->createCommand()->update('entries', array(
									'typeId'     => $entryTypeId,
									'authorId'   => null,
									'postDate'   => DateTimeHelper::currentTimeForDb(),
									'expiryDate' => null,
								), array(
									'id' => $singleEntryId
								));
							}

							// Make sure there's only one entry type for this section
							if ($entryTypeIds)
							{
								$this->deleteEntryTypeById($entryTypeIds);
							}
						}

						if (!$singleEntryId)
						{
							// Create it, baby

							craft()->db->createCommand()->insert('elements', array(
								'type' => ElementType::Entry
							));

							$singleEntryId = craft()->db->getLastInsertID();

							craft()->db->createCommand()->insert('entries', array(
								'id'        => $singleEntryId,
								'sectionId' => $section->id,
								'typeId'    => $entryTypeId,
								'postDate'  => DateTimeHelper::currentTimeForDb()
							));
						}

						// Now make sure we've got all of the i18n rows in place.
						foreach ($section->getLocales() as $localeId => $sectionLocale)
						{
							craft()->db->createCommand()->insertOrUpdate('elements_i18n', array(
								'elementId' => $singleEntryId,
								'locale'    => $localeId,
							), array(
								'uri'       => $sectionLocale->urlFormat
							));

							craft()->db->createCommand()->insertOrUpdate('content', array(
								'elementId' => $singleEntryId,
								'locale'    => $localeId
							), array(
								'title'     => $section->name
							));

							craft()->db->createCommand()->insertOrUpdate('entries_i18n', array(
								'entryId'   => $singleEntryId,
								'locale'    => $localeId
							), array(
								'sectionId' => $section->id,
								'slug'      => $section->handle
							));
						}

						break;
					}

					case SectionType::Structure:
					{
						if ($isNewSection || $oldSection->type != SectionType::Structure)
						{
							if (!$isNewSection)
							{
								// Find all of the entries in this section, before creating the root node
								$entryRecords = StructuredEntryRecord::model()->ordered()->findAllByAttributes(array(
									'sectionId' => $section->id
								));
							}

							// Create a root node
							craft()->db->createCommand()->insert('elements', array(
								'type'    => ElementType::Entry,
								'enabled' => false
							));

							$rootNodeRecord = new StructuredEntryRecord();
							$rootNodeRecord->id = craft()->db->getLastInsertID();
							$rootNodeRecord->sectionId = $section->id;
							$rootNodeRecord->saveNode();

							if (!$isNewSection)
							{
								// Place each of the existing entries under the root node
								foreach ($entryRecords as $entryRecord)
								{
									$entryRecord->appendTo($rootNodeRecord);
								}
							}
						}

						break;
					}
				}

				if ($transaction !== null)
				{
					$transaction->commit();
				}
			}
			catch (\Exception $e)
			{
				if ($transaction !== null)
				{
					$transaction->rollback();
				}

				throw $e;
			}

			return true;
		}
		else
		{
			return false;
		}
	}

	/**
	 * Deletes a section by its ID.
	 *
	 * @param int $sectionId
	 * @throws \Exception
	 * @return bool
	*/
	public function deleteSectionById($sectionId)
	{
		if (!$sectionId)
		{
			return false;
		}

		$transaction = craft()->db->getCurrentTransaction() === null ? craft()->db->beginTransaction() : null;
		try
		{
			// Grab the entry ids so we can clean the elements table.
			$entryIds = craft()->db->createCommand()
				->select('id')
				->from('entries')
				->where(array('sectionId' => $sectionId))
				->queryColumn();

			craft()->elements->deleteElementById($entryIds);

			// Delete the section.
			$affectedRows = craft()->db->createCommand()->delete('sections', array('id' => $sectionId));

			if ($transaction !== null)
			{
				$transaction->commit();
			}

			return (bool) $affectedRows;
		}
		catch (\Exception $e)
		{
			if ($transaction !== null)
			{
				$transaction->rollback();
			}

			throw $e;
		}
	}

	// Entry types

	/**
	 * Returns a section's entry types.
	 *
	 * @param int $sectionId
	 * @param string|null $indexBy
	 * @return array
	 */
	public function getEntryTypesBySectionId($sectionId, $indexBy = null)
	{
		$records = EntryTypeRecord::model()->ordered()->findAllByAttributes(array(
			'sectionId' => $sectionId
		));

		return EntryTypeModel::populateModels($records, $indexBy);
	}

	/**
	 * Returns an entry type by its ID.
	 *
	 * @param int $entryTypeId
	 * @return EntryTypeModel|null
	 */
	public function getEntryTypeById($entryTypeId)
	{
		if (!isset($this->_entryTypesById) || !array_key_exists($entryTypeId, $this->_entryTypesById))
		{
			$entryTypeRecord = EntryTypeRecord::model()->findById($entryTypeId);

			if ($entryTypeRecord)
			{
				$this->_entryTypesById[$entryTypeId] = EntryTypeModel::populateModel($entryTypeRecord);
			}
			else
			{
				$this->_entryTypesById[$entryTypeId] = null;
			}
		}

		return $this->_entryTypesById[$entryTypeId];
	}

	/**
	 * Saves an entry type.
	 *
	 * @param EntryTypeModel $entryType
	 * @throws \Exception
	 * @return bool
	 */
	public function saveEntryType(EntryTypeModel $entryType)
	{
		if ($entryType->id)
		{
			$entryTypeRecord = EntryTypeRecord::model()->findById($entryType->id);

			if (!$entryTypeRecord)
			{
				throw new Exception(Craft::t('No entry type exists with the ID “{id}”', array('id' => $entryTypeId)));
			}

			$isNewEntryType = false;
			$oldEntryType = EntryTypeModel::populateModel($entryTypeRecord);
		}
		else
		{
			$entryTypeRecord = new EntryTypeRecord();
			$isNewEntryType = true;
		}

		$entryTypeRecord->sectionId  = $entryType->sectionId;
		$entryTypeRecord->name       = $entryType->name;
		$entryTypeRecord->handle     = $entryType->handle;
		$entryTypeRecord->titleLabel = $entryType->titleLabel;

		$entryTypeRecord->validate();
		$entryType->addErrors($entryTypeRecord->getErrors());

		if (!$entryType->hasErrors())
		{
			$transaction = craft()->db->getCurrentTransaction() === null ? craft()->db->beginTransaction() : null;
			try
			{
				if (!$isNewEntryType && $oldEntryType->fieldLayoutId)
				{
					// Drop the old field layout
					craft()->fields->deleteLayoutById($oldEntryType->fieldLayoutId);
				}

				// Save the new one
				$fieldLayout = $entryType->getFieldLayout();
				craft()->fields->saveLayout($fieldLayout);

				// Update the entry type record/model with the new layout ID
				$entryType->fieldLayoutId = $fieldLayout->id;
				$entryTypeRecord->fieldLayoutId = $fieldLayout->id;

				$entryTypeRecord->save(false);

				// Now that we have an entry type ID, save it on the model
				if (!$entryType->id)
				{
					$entryType->id = $entryTypeRecord->id;
				}

				// Might as well update our cache of the entry type while we have it.
				$this->_entryTypesById[$entryType->id] = $entryType;

				if ($transaction !== null)
				{
					$transaction->commit();
				}
			}
			catch (\Exception $e)
			{
				if ($transaction !== null)
				{
					$transaction->rollback();
				}

				throw $e;
			}

			return true;
		}
		else
		{
			return false;
		}
	}

	/**
	 * Deletes an entry type(s) by its ID.
	 *
	 * @param int|array $entryTypeId
	 * @throws \Exception
	 * @return bool
	*/
	public function deleteEntryTypeById($entryTypeId)
	{
		if (!$entryTypeId)
		{
			return false;
		}

		$transaction = craft()->db->getCurrentTransaction() === null ? craft()->db->beginTransaction() : null;
		try
		{
			// Delete the field layout
			 $query = craft()->db->createCommand()
				->select('fieldLayoutId')
				->from('entrytypes');

			if (is_array($entryTypeId))
			{
				$query->where(array('in', 'id', $entryTypeId));
			}
			else
			{
				$query->where(array('id' => $entryTypeId));
			}

			$fieldLayoutIds = $query->queryColumn();

			if ($fieldLayoutIds)
			{
				craft()->fields->deleteLayoutById($fieldLayoutIds);
			}

			// Grab the entry IDs so we can clean the elements table.
			$query = craft()->db->createCommand()
				->select('id')
				->from('entries');

			if (is_array($entryTypeId))
			{
				$query->where(array('in', 'typeId', $entryTypeId));
			}
			else
			{
				$query->where(array('typeId' => $entryTypeId));
			}

			$entryIds = $query->queryColumn();

			craft()->elements->deleteElementById($entryIds);

			// Delete the entry type.
			if (is_array($entryTypeId))
			{
				$affectedRows = craft()->db->createCommand()->delete('entrytypes', array('in', 'id', $entryTypeId));
			}
			else
			{
				$affectedRows = craft()->db->createCommand()->delete('entrytypes', array('id' => $entryTypeId));
			}

			if ($transaction !== null)
			{
				$transaction->commit();
			}

			return (bool) $affectedRows;
		}
		catch (\Exception $e)
		{
			if ($transaction !== null)
			{
				$transaction->rollback();
			}

			throw $e;
		}
	}

	// General stuff

	/**
	 * Returns whether a homepage section exists.
	 *
	 * @return bool
	 */
	public function doesHomepageExist()
	{
		$conditions = array('and', 'sections.type = :type', 'sections_i18n.urlFormat = :homeUri');
		$params = array(':type' => SectionType::Single, ':homeUri' => '__home__');

		$count = craft()->db->createCommand()
			->from('sections sections')
			->join('sections_i18n sections_i18n', 'sections_i18n.sectionId = sections.id')
			->where($conditions, $params)
			->count('sections.id');

		return (bool) $count;
	}

	/**
	 * Returns whether another section can be added of a given type.
	 *
	 * @param string $type
	 * @return bool
	 */
	public function canHaveMore($type)
	{
		if (Craft::hasPackage(CraftPackage::PublishPro))
		{
			return true;
		}
		else
		{
			if (isset($this->typeLimits[$type]))
			{
				$count = craft()->db->createCommand()
					->from('sections')
					->where('type = :type', array(':type' => $type))
					->count('id');

				return $count < $this->typeLimits[$type];
			}
			else
			{
				return false;
			}
		}
	}
}
