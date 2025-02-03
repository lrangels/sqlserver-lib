/*#info 

	# Author 
		Rodrigo Ribeiro Gomes 

	# DEtalhes 
		Tenta descobrir a frequencia com que o backup é feito!

*/

-- Created  by Rodrigo Ribeiro Gomes (www.thesqltimes.com)
DECLARE
	@RefDate		datetime
	,@considerCopyOnly bit
	,@CustomWhere nvarchar(max)
	,@FullTolerance int
	,@DiffTolerance int
	,@LogTolerance int


SET @RefDate = '20250101';
SET @considerCopyOnly	= 0;		--> Control if script must include backups taken with "COPY_ONLY" (2005+) option.
SET @CustomWhere		= NULL;		--> You can write a custom msdb filter. This filter will be applied before filters above.
SET  @FullTolerance		= 60		--> controla o arrendondamento...
SET  @DiffTolerance		= 60		
SET  @LogTolerance		= 60

/*
	Results descriptions:


*/

---------

IF OBJECT_ID('tempdb..#BackupFinalData') IS NOT NULL
	DROP TABLE #BackupFinalData;

IF OBJECT_ID('tempdb..#BackupInfo') IS NOT NULL
	DROP TABLE #BackupInfo;

	CREATE TABLE #BackupInfo(
		 backup_set_id bigint
		,database_name sysname
		,backup_finish_date datetime
		,type varchar(5)
		,backup_size numeric(20,0)
		,compressed_backup_size numeric(20,0)
	
	)

IF LEN(@CustomWhere ) = 0
	SET @CustomWhere = NULL;


DECLARE 
	@cmd nvarchar(4000)
	,@compressedExpr nvarchar(100)
	,@copyOnly nvarchar(500)
	,@sqlVersion int
;

-- Getting SQL Version
SELECT @sqlVersion = LEFT(V.Ver,CHARINDEX('.',V.Ver)-1) FROM (SELECT  CONVERT(varchar(30),SERVERPROPERTY('ProductVersion')) as Ver) V


-- If supports compression, then add compression column.

IF EXISTS(SELECT * FROM msdb.INFORMATION_SCHEMA.COLUMNS C WHERE C.TABLE_NAME = 'backupset' AND COLUMN_NAME = 'compressed_backup_size')
	SET @compressedExpr = 'BS.compressed_backup_size';
ELSE
	SET @compressedExpr = 'BS.backup_size';

IF EXISTS(SELECT * FROM msdb.INFORMATION_SCHEMA.COLUMNS C WHERE C.TABLE_NAME = 'backupset' AND COLUMN_NAME = 'is_copy_only')
	SET @copyOnly = 'BS.is_copy_only = 0';
ELSE
	SET @copyOnly = NULL;

IF ISNULL(@considerCopyOnly,0) = 1
	SET @copyOnly = NULL;

--> Query for collect base backup data
SET @cmd = N'
	INSERT INTO
		#BackupInfo
	SELECT -- The DISTINCT remove duplicates generated by join
		 BS.backup_set_id
		,BS.database_name
		,BS.backup_finish_date
		,BS.type
		,BS.backup_size
		,'+@compressedExpr+' as compressedSize
	FROM	
		(
			SELECT
				*
			FROM
				msdb.dbo.backupset BS
			WHERE
				1 = 1
			-- #CustomWhereFilter
				'+ISNULL(' AND ('+@CustomWhere+')','')+'
		) BS
	WHERE
		BS.backup_finish_date >= @RefDate

		'+ISNULL('AND '+@copyOnly,'')+'
'
-- Run Query!
EXEC sp_executesql @cmd,N'@RefDate datetime',@RefDate;

CREATE CLUSTERED INDEX ixCluster ON #BackupInfo(database_name,type,backup_set_id);

IF OBJECT_ID('tempdb..#RawFreqAgg') IS NOT NULL
	DROP TABLE #RawFreqAgg;

IF OBJECT_ID('tempdb..#FreqInfo') IS NOT NULL
	DROP TABLE #FreqInfo;
 
--> Aqui vamos calcular o intervalo do backup...
--> E vamos normalizar para um múltiplo da tolerancia...
--- Ex,: Toleracnia é 3600 (1h), e backup feito( 3720)... é considerado como 3600
SELECT
	BI.*
	,OriginalFreq
	,Freq = CASE BI.type
						WHEN 'D' THEN CONVERT(int,OriginalFreq/@FullTolerance) * @FullTolerance
						WHEN 'I' THEN CONVERT(int,OriginalFreq/@DiffTolerance)* @DiffTolerance 
						WHEN 'L' THEN CONVERT(int,OriginalFreq/@LogTolerance)* @LogTolerance
					END
INTO
	#FreqInfo
FROM
	#BackupInfo	BI
	--> pegar o backup anterior a este!
	CROSS APPLY 
	(
		SELECT TOP 1
			*
			,OriginalFreq = DATEDIFF(SS,BIA.backup_finish_date,BI.backup_finish_date)
		FROM
			#BackupInfo BIA
		WHERE
			BIA.backup_set_id < BI.backup_set_id
			AND
			BIA.database_name = BI.database_name
			AND
			BIA.type = BI.type
		ORDER BY
			BIA.backup_set_id DESC
	) BA

IF OBJECT_ID('tempdb..#FreqTable') IS NOT NULL
	DROP TABLE #FreqTable;

--. Agora vamos encontrar a frequencia mais provavel!
--> Um banco pode ter passado por varias frequencias diferentes (ser feito todo dia 1h, mas em um dia anromal, ter sido feito a cada 2h).
--> Vamos identificar essas repeticoes e escolher a que mais se repete!

--> Primeiro, vamos calculaas frequencias distintas e sus qtds.
SELECT
	*
	--> Seq é 1 para a freq mais repetida... Se 2 frequencias são iguais, entao usa que tem o maior backup set id.
	,Seq = ROW_NUMBER() OVER(PARTITION BY database_name,type ORDER BY FreqCount DESC,LastBackuupId DESC) 
INTO
	#FreqTable
FROM
	(
		SELECT
			 database_name
			,type
			,Freq
			,Freqcount = COUNT(*)
			,LastBackuupId = MAX(backup_set_id)
		FROM
			#FreqInfo
		GROUP BY
			database_name
				,type	
				,Freq
	) F
	
CREATE UNIQUE CLUSTERED INDEX ixCluster ON #FreqTable(database_name,type,Seq);


--> Agora vamos escolher as que são responsaveis por 50% do total!
-- Por isso, pode aparecer mais de um!
SELECT
	*
FROM
(
	SELECT
		FT.*
		,TF.TotalFreq
		,PrevFrqPerc = rf.PrevFreqCount*1.0/tf.TotalFreq
		,CurrentFreqPerc = ft.Freqcount*1.0/tf.TotalFreq
	FROM
		#FreqTable FT
		CROSS APPLY
		(
			--> Total de frequencias para o mesmo banco/tipo
			SELECT 
				TotalFreq = SUM(Freqcount) 
			FROM 
				#FreqTable FTB 
			WHERE 
				FTB.database_name = FT.database_name 
				AND 
				FTB.type = FT.type 
		) TF
		OUTER APPLY
		(
			SELECT 
				PrevFreqCount = ISNULL((SUM(Freqcount)*1.),0)
			FROM 
				#FreqTable FTB 
			WHERE 
				FTB.database_name = FT.database_name 
				AND 
				FTB.type = FT.type 
				AND
				FTB.Seq < FT.Seq
		) RF
	where
		--> Vamos escolher somente cujo as freq anteriores seja menor que 50%, significa que té a atual, é responsável por 50% do total!
		rf.PrevFreqCount*1.0/tf.TotalFreq  < 0.5
) FF
CROSS APPLY
(
	
	SELECT
		FreqFormatted = 'A cada: '+ISNULL(NULLIF(t.Y+'y','0y'),'')
		+ISNULL(NULLIF(t.Mo+'mo','0mo'),'')
		+ISNULL(NULLIF(t.D+'d','0d'),'')
		+ISNULL(NULLIF(t.H+'h','0h'),'')
		+ISNULL(NULLIF(t.M+'m','0m'),'')
		+ISNULL(NULLIF(t.S+'s','0s'),'') 
	FROM
	(
		SELECT	
			 CONVERT(varchar(10),(RF.RawFreq%60))			as S
			,CONVERT(varchar(10),(RF.RawFreq/60)%60)		as M
			,CONVERT(varchar(10),(RF.RawFreq/3600)%24)		as H
			,CONVERT(varchar(10),(RF.RawFreq/86400)%30)	as D
			,CONVERT(varchar(10),(RF.RawFreq/2592000)%12)	as Mo
			,CONVERT(varchar(10),(RF.RawFreq/31104000))	as Y
		FROM
			(
				SELECT RawFreq = FF.Freq
			) RF
	) t
) F
	order by	
		database_name,type,seq






